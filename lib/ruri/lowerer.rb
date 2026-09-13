# frozen_string_literal: true

module Ruri
  # Converts validated, language-level Forms into a generic Emacs Lisp AST.
  # This is the only component that knows how a Ruri construct maps to Lisp.
  class Lowerer
    class << self
      def lower(definitions)
        new.lower(definitions)
      end
    end

    # Nested loops and definitions allocate deterministic catch tags
    # (ruri--break-1, ruri--return-2, ...) in lowering order; the stacks
    # track which tag break/next/return currently throw to.
    def initialize
      @exit_tag_counter = 0
      @break_tags = []
      @next_tags = []
      @return_tags = []
    end

    # Boundaries where an exit belongs to the inner construct: nested loops
    # own their break/next, lambdas own their returns, let blocks own
    # neither (the parser rejects exits crossing a let).
    LOOP_EXIT_BOUNDARIES = [
      Forms::Lambda, Forms::Loop, Forms::Each, Forms::Iteration,
      Forms::Times, Forms::Let
    ].freeze

    # `.map` → mapcar, `.select` → seq-filter, `.find` → seq-find. The
    # latter two need `(require 'seq)` in the source, like any seq use.
    ITERATION_CALLS = {
      "map" => "mapcar",
      "select" => "seq-filter",
      "find" => "seq-find"
    }.freeze

    def lower(definitions)
      definitions.map do |definition|
        case definition
        when Forms::Command then lower_command(definition)
        when Forms::FunctionDefinition then lower_function_definition(definition)
        when Forms::VariableDefinition then lower_variable_definition(definition, "defvar")
        when Forms::ConstantDefinition then lower_variable_definition(definition, "defconst")
        when Forms::VariableLocalDefinition then lower_variable_definition(definition, "defvar-local")
        when Forms::CustomDefinition then lower_custom_definition(definition)
        when Forms::Require then lower_feature(definition, "require")
        when Forms::Provide then lower_feature(definition, "provide")
        else raise ArgumentError, "cannot lower Ruri definition: #{definition.class}"
        end
      end
    end

    private

    def lower_command(command)
      doc_form, statements = partition_docstring(command.body)
      interactive_form, *rest = statements
      return_tag = enter_return_scope(command.body)
      lowered_rest = rest.map { |statement| lower_statement(statement) }
      leave_return_scope(return_tag)
      locals = collect_locals(rest)
      lowered_rest = wrap_locals(locals, lowered_rest) unless locals.empty?
      lowered_rest = lower_parameter_defaults(command.parameters) + lowered_rest
      lowered_rest = [catch_wrap(return_tag, lowered_rest)] if return_tag

      Elisp.list(
        Elisp.symbol("defun"),
        Elisp.symbol(command.name),
        lower_parameter_list(command.parameters),
        *doc_form,
        lower_statement(interactive_form),
        *lowered_rest
      )
    end

    def lower_function_definition(function)
      doc_form, statements = partition_docstring(function.body)
      return_tag = enter_return_scope(function.body)
      lowered = statements.map { |statement| lower_statement(statement) }
      leave_return_scope(return_tag)
      locals = collect_locals(statements, [], function.parameters.names)
      lowered = wrap_locals(locals, lowered) unless locals.empty?
      lowered = lower_parameter_defaults(function.parameters) + lowered
      lowered = [catch_wrap(return_tag, lowered)] if return_tag

      Elisp.list(
        Elisp.symbol("defun"),
        Elisp.symbol(function.name),
        lower_parameter_list(function.parameters),
        *doc_form,
        *lowered
      )
    end

    # `return` has no defun equivalent, so a body containing one (without
    # crossing into a nested fn) is wrapped in `(catch 'ruri--return-N ...)`
    # and each return throws to it. Bodies without returns emit unchanged.
    # The tag is pushed before lowering so nested returns resolve to the
    # innermost enclosing scope.
    def enter_return_scope(body_forms)
      return nil unless body_has_exit?(body_forms, Forms::Return, [Forms::Lambda])

      tag = allocate_tag("return")
      @return_tags.push(tag)
      tag
    end

    def leave_return_scope(tag)
      @return_tags.pop if tag
    end

    def body_has_exit?(statements, klass, boundaries)
      statements.any? { |form| form_has_exit?(form, klass, boundaries) }
    end

    def form_has_exit?(form, klass, boundaries)
      return true if form.instance_of?(klass)
      return false if boundaries.any? { |boundary| form.instance_of?(boundary) }

      case form
      when Forms::Conditional
        body_has_exit?(form.then_body, klass, boundaries) ||
          body_has_exit?(form.else_body, klass, boundaries)
      when Forms::Loop
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Each
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Iteration
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Times
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Rescue
        body_has_exit?(form.body, klass, boundaries) ||
          form.clauses.any? { |_, body| body_has_exit?(body, klass, boundaries) } ||
          body_has_exit?(form.else_body, klass, boundaries)
      when Forms::Ensure
        body_has_exit?(form.body, klass, boundaries) ||
          body_has_exit?(form.ensure_body, klass, boundaries)
      when Forms::Catch
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Let
        body_has_exit?(form.body, klass, boundaries)
      when Forms::WithCurrentBuffer
        body_has_exit?(form.body, klass, boundaries)
      when Forms::Call
        body_has_exit?(form.body, klass, boundaries)
      when Forms::PlaceOperation
        if form.place.is_a?(Forms::Call)
          form_has_exit?(form.place, klass, boundaries)
        else
          false
        end || form.arguments.any? { |argument| form_has_exit?(argument, klass, boundaries) }
      else
        false
      end
    end

    def allocate_tag(kind)
      @exit_tag_counter += 1
      "ruri--#{kind}-#{@exit_tag_counter}"
    end

    def catch_wrap(tag, forms)
      Elisp.list(
        Elisp.symbol("catch"),
        Elisp.quote(Elisp.symbol(tag)),
        *forms
      )
    end

    # The defun argument list: required names, then `&optional` and `&rest`
    # sections in binding order.
    def lower_parameter_list(parameters)
      items = parameters.required.map { |name| Elisp.symbol(name) }
      unless parameters.optionals.empty?
        items << Elisp.symbol("&optional")
        parameters.optionals.each { |optional| items << Elisp.symbol(optional.name) }
      end
      if parameters.rest
        items << Elisp.symbol("&rest")
        items << Elisp.symbol(parameters.rest.name)
      end
      Elisp.inline_list(*items)
    end

    # Optional parameters with an expression default are applied at entry
    # with `(unless name (setq name default))`, because plain defun
    # arguments have no per-argument default form. A literal nil or false
    # default lowers to nil, which is exactly Elisp's own behavior, so it
    # needs no code.
    def lower_parameter_defaults(parameters)
      parameters.optionals.filter_map do |optional|
        next nil if nil_default?(optional.default)

        name = Elisp.symbol(optional.name)
        Elisp.list(
          Elisp.symbol("unless"),
          name,
          Elisp.list(Elisp.symbol("setq"), name, lower_expression(optional.default))
        )
      end
    end

    def nil_default?(default)
      default.is_a?(Forms::Literal) && %i[nil false].include?(default.kind)
    end

    # The parser places at most one Forms::Docstring at the head of a
    # definition body. It lowers to a dedicated node and stays outside any
    # lexical `let`, matching conventional Elisp layout.
    def partition_docstring(statements)
      if statements.first.is_a?(Forms::Docstring)
        [lower_docstring(statements.first), statements[1..]]
      else
        [[], statements]
      end
    end

    def lower_variable_definition(definition, lisp_form)
      items = [Elisp.symbol(lisp_form), Elisp.symbol(definition.name)]
      items << lower_expression(definition.value) if definition.value
      items << lower_docstring_text(definition.docstring) if definition.docstring
      Elisp.list(*items)
    end

    def lower_custom_definition(definition)
      items = [
        Elisp.symbol("defcustom"),
        Elisp.symbol(definition.name),
        lower_expression(definition.value)
      ]
      items << lower_docstring_text(definition.docstring) if definition.docstring
      definition.keywords.each do |key, expression|
        items << Elisp.inline_sequence(
          Elisp.symbol(":#{key}"),
          lower_expression(expression)
        )
      end
      Elisp.list(*items)
    end

    def lower_feature(definition, lisp_form)
      Elisp.list(
        Elisp.symbol(lisp_form),
        Elisp.quote(Elisp.symbol(definition.name))
      )
    end

    def lower_docstring_text(text)
      Elisp.docstring(Elisp.string(text))
    end

    def wrap_locals(locals, forms)
      [Elisp.list(
        Elisp.symbol("let"),
        Elisp.inline_list(*locals.map { |name| Elisp.symbol(name) }),
        *forms
      )]
    end

    def lower_docstring(docstring)
      lower_docstring_text(docstring.text)
    end

    def collect_locals(statements, names = [], shadowed = [])
      statements.each do |statement|
        case statement
        when Forms::LocalWrite
          unless shadowed.include?(statement.name) || names.include?(statement.name)
            names << statement.name
          end
          collect_expression_locals(statement.value, names, shadowed)
        when Forms::WithCurrentBuffer
          collect_locals(statement.body, names, shadowed)
        when Forms::Conditional
          collect_expression_locals(statement.condition, names, shadowed)
          collect_locals(statement.then_body, names, shadowed)
          collect_locals(statement.else_body, names, shadowed)
        when Forms::Loop
          collect_expression_locals(statement.condition, names, shadowed)
          collect_locals(statement.body, names, shadowed)
        when Forms::Each
          collect_expression_locals(statement.collection, names, shadowed)
          collect_locals(statement.body, names, shadowed + [statement.parameter])
        when Forms::Iteration
          collect_expression_locals(statement.collection, names, shadowed)
          collect_locals(statement.body, names, shadowed + [statement.parameter])
        when Forms::Times
          collect_expression_locals(statement.count, names, shadowed)
          collect_locals(statement.body, names, shadowed + [statement.parameter])
        when Forms::Rescue
          # The condition-case binding shadows the outer let inside the
          # form, but the name stays declared so reads after the block see
          # nil the way Ruby's leaky rescue locals do.
          if statement.var && !names.include?(statement.var)
            names << statement.var
          end
          collect_locals(statement.body, names, shadowed)
          statement.clauses.each { |_, body| collect_locals(body, names, shadowed) }
          collect_locals(statement.else_body, names, shadowed)
        when Forms::Ensure
          collect_locals(statement.body, names, shadowed)
          collect_locals(statement.ensure_body, names, shadowed)
        when Forms::Catch
          collect_locals(statement.body, names, shadowed)
        when Forms::Let
          collect_locals(statement.body, names, shadowed + statement.parameters.names)
        when Forms::Throw
          collect_expression_locals(statement.value, names, shadowed)
        when Forms::PlaceOperation
          collect_expression_locals(statement.place, names, shadowed) if statement.place.is_a?(Forms::Call)
          statement.arguments.each { |argument| collect_expression_locals(argument, names, shadowed) }
        when Forms::Break, Forms::Next, Forms::Return
          collect_expression_locals(statement.value, names, shadowed) if statement.value
        when Forms::Call
          collect_expression_locals(statement, names, shadowed)
        when Forms::ExpressionStatement
          collect_expression_locals(statement.expression, names, shadowed)
        end
      end
      names
    end

    def collect_expression_locals(expression, names, shadowed)
      case expression
      when Forms::Call
        expression.arguments.each do |argument|
          collect_expression_locals(argument, names, shadowed)
        end
        collect_locals(expression.body, names, shadowed)
      when Forms::Vector
        expression.elements.each do |element|
          collect_expression_locals(element, names, shadowed)
        end
      when Forms::ListValue
        expression.elements.each do |element|
          collect_expression_locals(element, names, shadowed)
        end
      when Forms::ConsValue
        collect_expression_locals(expression.car, names, shadowed)
        collect_expression_locals(expression.cdr, names, shadowed)
      when Forms::Lambda
        collect_locals(expression.body, names, shadowed + expression.parameters.names)
      when Forms::QuasiQuote
        collect_template_locals(expression.value, names, shadowed)
      when Forms::Operation
        expression.arguments.each do |argument|
          collect_expression_locals(argument, names, shadowed)
        end
      when Forms::Rescue
        if expression.var && !names.include?(expression.var)
          names << expression.var
        end
        collect_locals(expression.body, names, shadowed)
        expression.clauses.each { |_, body| collect_locals(body, names, shadowed) }
        collect_locals(expression.else_body, names, shadowed)
      when Forms::Ensure
        collect_locals(expression.body, names, shadowed)
        collect_locals(expression.ensure_body, names, shadowed)
      when Forms::Catch
        collect_locals(expression.body, names, shadowed)
      when Forms::Throw
        collect_expression_locals(expression.value, names, shadowed)
      when Forms::Let
        collect_locals(expression.body, names, shadowed + expression.parameters.names)
      when Forms::PlaceOperation
        collect_expression_locals(expression.place, names, shadowed) if expression.place.is_a?(Forms::Call)
        expression.arguments.each { |argument| collect_expression_locals(argument, names, shadowed) }
      when Forms::Iteration
        collect_expression_locals(expression.collection, names, shadowed)
        collect_locals(expression.body, names, shadowed + [expression.parameter])
      end
    end

    def collect_template_locals(value, names, shadowed)
      case value
      when Forms::Unquote, Forms::Splice
        collect_expression_locals(value.value, names, shadowed)
      when Forms::QuasiQuote
        # Nested templates carry only data: their escapes bind or read
        # nothing in the surrounding definition.
        collect_template_locals(value.value, names, shadowed)
      when Forms::ListValue, Forms::Vector
        value.elements.each { |element| collect_template_locals(element, names, shadowed) }
      when Forms::ConsValue
        collect_template_locals(value.car, names, shadowed)
        collect_template_locals(value.cdr, names, shadowed)
      end
    end

    def lower_statement(statement)
      case statement
      when Forms::Interactive
        items = [Elisp.symbol("interactive")]
        items << lower_expression(statement.spec) if statement.spec
        Elisp.list(*items)
      when Forms::Docstring
        lower_docstring(statement)
      when Forms::Insert
        Elisp.list(Elisp.symbol("insert"), Elisp.string(statement.text))
      when Forms::WithCurrentBuffer
        Elisp.list(
          Elisp.symbol("with-current-buffer"),
          Elisp.string(statement.buffer),
          *statement.body.map { |child| lower_statement(child) }
        )
      when Forms::Call
        lower_call(statement)
      when Forms::LocalWrite
        Elisp.list(
          Elisp.symbol("setq"),
          Elisp.symbol(statement.name),
          lower_expression(statement.value)
        )
      when Forms::Conditional
        lower_conditional(statement)
      when Forms::Loop
        lower_loop(statement)
      when Forms::Each
        lower_each(statement)
      when Forms::Iteration
        lower_iteration(statement)
      when Forms::Times
        lower_times(statement)
      when Forms::Rescue
        lower_rescue(statement)
      when Forms::Ensure
        lower_ensure(statement)
      when Forms::Catch
        lower_catch(statement)
      when Forms::Throw
        lower_throw(statement)
      when Forms::Let
        lower_let(statement)
      when Forms::PlaceOperation
        lower_place_operation(statement)
      when Forms::Break
        lower_exit(statement, @break_tags.last)
      when Forms::Next
        lower_exit(statement, @next_tags.last)
      when Forms::Return
        lower_exit(statement, @return_tags.last)
      when Forms::ExpressionStatement
        lower_expression(statement.expression)
      when Forms::Assign
        items = [Elisp.symbol("setq")]
        statement.pairs.each do |name, value|
          items << Elisp.symbol(name)
          items << lower_expression(value)
        end
        Elisp.list(*items)
      else
        raise ArgumentError, "cannot lower Ruri form: #{statement.class}"
      end
    end

    def lower_call(call)
      Elisp.list(
        Elisp.symbol(call.name),
        *call.arguments.map { |argument| lower_expression(argument) },
        *call.body.map { |statement| lower_statement(statement) }
      )
    end

    def lower_expression(expression)
      case expression
      when Forms::Call
        lower_call(expression)
      when Forms::Vector
        Elisp.list(
          Elisp.symbol("vector"),
          *expression.elements.map { |element| lower_expression(element) }
        )
      when Forms::ListValue
        Elisp.list(
          Elisp.symbol("list"),
          *expression.elements.map { |element| lower_expression(element) }
        )
      when Forms::ConsValue
        Elisp.list(
          Elisp.symbol("cons"),
          lower_expression(expression.car),
          lower_expression(expression.cdr)
        )
      when Forms::Literal
        lower_literal(expression)
      when Forms::LocalRead
        Elisp.symbol(expression.name)
      when Forms::VarRead
        Elisp.symbol(expression.name)
      when Forms::Keyword
        Elisp.symbol(expression.name)
      when Forms::Lambda
        return_tag = enter_return_scope(expression.body)
        lambda_body = expression.body.map { |statement| lower_statement(statement) }
        leave_return_scope(return_tag)
        lambda_body = [catch_wrap(return_tag, lambda_body)] if return_tag
        Elisp.list(
          Elisp.symbol("lambda"),
          lower_parameter_list(expression.parameters),
          *lower_parameter_defaults(expression.parameters),
          *lambda_body
        )
      when Forms::FunctionReference
        Elisp.list(
          Elisp.symbol("function"),
          Elisp.symbol(expression.name)
        )
      when Forms::Quote
        Elisp.quote(lower_quoted_data(expression.value))
      when Forms::QuasiQuote
        Elisp.quasiquote(lower_quoted_data(expression.value))
      when Forms::Operation
        operation = Elisp.list(
          Elisp.symbol(expression.name),
          *expression.arguments.map { |argument| lower_expression(argument) }
        )
        expression.negated ? Elisp.list(Elisp.symbol("not"), operation) : operation
      when Forms::Rescue
        lower_rescue(expression)
      when Forms::Ensure
        lower_ensure(expression)
      when Forms::Iteration
        lower_iteration(expression)
      when Forms::Catch
        lower_catch(expression)
      when Forms::Throw
        lower_throw(expression)
      when Forms::Let
        lower_let(expression)
      when Forms::PlaceOperation
        lower_place_operation(expression)
      else
        raise ArgumentError, "cannot lower Ruri expression: #{expression.class}"
      end
    end

    # (catch 'tag FORMS...): the tag is a quoted symbol in an unevaluated
    # position; the result is the thrown value or the last body form.
    def lower_catch(catch_form)
      Elisp.list(
        Elisp.symbol("catch"),
        Elisp.quote(Elisp.symbol(catch_form.tag)),
        *catch_form.body.map { |statement| lower_statement(statement) }
      )
    end

    def lower_throw(throw_form)
      Elisp.list(
        Elisp.symbol("throw"),
        Elisp.quote(Elisp.symbol(throw_form.tag)),
        lower_expression(throw_form.value)
      )
    end

    # Typed place operations lower with the place in its unevaluated
    # position: (setf PLACE VALUE), (cl-incf PLACE [DELTA]), (pop PLACE),
    # and push with its arguments reversed to (push VALUE PLACE). A
    # variable or local place lowers to a bare symbol; a form place to
    # the lowered call.
    def lower_place_operation(operation)
      place = case operation.place
              when Forms::Call then lower_expression(operation.place)
              else Elisp.symbol(operation.place.name)
              end
      values = operation.arguments.map { |argument| lower_expression(argument) }
      items = if operation.name == "push"
                [Elisp.symbol("push"), *values, place]
              else
                [Elisp.symbol(operation.name), place, *values]
              end
      Elisp.list(*items)
    end

    # `let` lowers to let*: the parser parsed each initializer with only
    # the earlier bindings in scope, so sequential binding is the
    # contract. A parameter without a default (or with a literal
    # nil/false one) binds nil explicitly — the bare-symbol `(let* (x))`
    # shape draws a byte-compiler "left uninitialized" warning.
    def lower_let(let_form)
      bindings = let_form.parameters.required.map do |name|
        Elisp.list(Elisp.symbol(name), Elisp.symbol("nil"))
      end
      let_form.parameters.optionals.each do |optional|
        bindings << if nil_default?(optional.default)
                      Elisp.list(Elisp.symbol(optional.name), Elisp.symbol("nil"))
                    else
                      Elisp.list(
                        Elisp.symbol(optional.name),
                        lower_expression(optional.default)
                      )
                    end
      end
      Elisp.list(
        Elisp.symbol("let*"),
        Elisp.list(*bindings),
        *let_form.body.map { |statement| lower_statement(statement) }
      )
    end

    # break/next/return become throws against the current innermost tag;
    # a bare exit carries nil because Elisp throw requires a value.
    def lower_exit(statement, tag)
      Elisp.list(
        Elisp.symbol("throw"),
        Elisp.quote(Elisp.symbol(tag)),
        statement.value ? lower_expression(statement.value) : Elisp.symbol("nil")
      )
    end

    # (condition-case VAR BODY CLAUSES...) where each clause is
    # ((CONDITIONS...) FORMS...); a body or handler's final form supplies
    # the value. `else` becomes a (:success ...) handler, whose value wins
    # when nothing was signalled. A single body form is emitted directly.
    def lower_rescue(rescue_form)
      items = [
        Elisp.symbol("condition-case"),
        rescue_form.var ? Elisp.symbol(rescue_form.var) : Elisp.symbol("nil"),
        *protected_body(rescue_form.body)
      ]
      rescue_form.clauses.each do |conditions, body|
        items << Elisp.list(
          Elisp.inline_list(*conditions.map { |name| Elisp.symbol(name) }),
          *body.map { |statement| lower_statement(statement) }
        )
      end
      unless rescue_form.else_body.empty?
        items << Elisp.list(
          Elisp.symbol(":success"),
          *rescue_form.else_body.map { |statement| lower_statement(statement) }
        )
      end
      Elisp.list(*items)
    end

    def protected_body(statements)
      forms = statements.map { |statement| lower_statement(statement) }
      return [Elisp.symbol("nil")] if forms.empty?

      return forms if forms.one?

      [Elisp.list(Elisp.symbol("progn"), *forms)]
    end

    # (unwind-protect BODY FORMS...): the cleanup forms always run, and the
    # result is the body's value even on the error path.
    def lower_ensure(ensure_form)
      Elisp.list(
        Elisp.symbol("unwind-protect"),
        *protected_body(ensure_form.body),
        *ensure_form.ensure_body.map { |statement| lower_statement(statement) }
      )
    end

    def lower_quoted_data(value)
      case value
      when Forms::Literal
        lower_data_literal(value)
      when Forms::ListValue
        Elisp.list(*value.elements.map { |element| lower_quoted_data(element) })
      when Forms::ConsValue
        Elisp.dotted_pair(
          lower_quoted_data(value.car),
          lower_quoted_data(value.cdr)
        )
      when Forms::Vector
        Elisp.vector(*value.elements.map { |element| lower_quoted_data(element) })
      when Forms::Quote
        Elisp.quote(lower_quoted_data(value.value))
      when Forms::QuasiQuote
        Elisp.quasiquote(lower_quoted_data(value.value))
      when Forms::Unquote
        Elisp.unquote(lower_expression(value.value))
      when Forms::Splice
        Elisp.splice(lower_expression(value.value))
      # Depth ≥ 2 escapes stay data: their content was parsed as quoted
      # data, so the unquote/splice is emitted around it for the inner
      # template's own evaluation.
      when Forms::NestedUnquote
        Elisp.unquote(lower_quoted_data(value.value))
      when Forms::NestedSplice
        Elisp.splice(lower_quoted_data(value.value))
      else
        raise ArgumentError, "cannot lower quoted Ruri data: #{value.class}"
      end
    end

    def lower_data_literal(literal)
      case literal.kind
      when :string then Elisp.string(literal.value)
      when :integer then Elisp.integer(literal.value)
      when :float then Elisp.float(literal.value)
      when :true then Elisp.symbol("t")
      when :false, :nil then Elisp.symbol("nil")
      when :symbol then Elisp.symbol(literal.value)
      else
        raise ArgumentError, "cannot lower Ruri data literal: #{literal.kind}"
      end
    end

    def lower_conditional(conditional)
      condition = lower_expression(conditional.condition)
      if conditional.negated
        condition = Elisp.list(Elisp.symbol("not"), condition)
      end

      items = [
        Elisp.symbol("if"),
        condition,
        lower_branch(conditional.then_body)
      ]
      items << lower_branch(conditional.else_body) unless conditional.else_body.empty?
      Elisp.list(*items)
    end

    # Loops get catch tags only when their body (not crossing a nested
    # loop or fn) actually contains break/next, so plain loops emit
    # unchanged. `next` is caught per iteration; `break` unwinds the
    # whole loop.
    def lower_loop(loop)
      condition = lower_expression(loop.condition)
      condition = Elisp.list(Elisp.symbol("not"), condition) if loop.negated
      break_tag, next_tag = enter_loop_scopes(loop.body)
      body = loop.body.map { |statement| lower_statement(statement) }
      leave_loop_scopes(break_tag, next_tag)
      body = [catch_wrap(next_tag, body)] if next_tag
      loop_form = Elisp.list(Elisp.symbol("while"), condition, *body)
      loop_form = catch_wrap(break_tag, [loop_form]) if break_tag
      loop_form
    end

    def lower_each(each_form)
      lower_block_iteration(each_form) do |lambda_form|
        Elisp.list(
          Elisp.symbol("mapc"),
          lambda_form,
          lower_expression(each_form.collection)
        )
      end
    end

    def lower_iteration(iteration)
      lower_block_iteration(iteration) do |lambda_form|
        Elisp.list(
          Elisp.symbol(ITERATION_CALLS.fetch(iteration.name)),
          lambda_form,
          lower_expression(iteration.collection)
        )
      end
    end

    # `count.times` lowers to dotimes with an inline (COUNTER COUNT)
    # binding and the body as trailing forms. The value is nil, matching
    # dotimes rather than Ruby's Integer#times.
    def lower_times(times_form)
      break_tag, next_tag = enter_loop_scopes(times_form.body)
      body = times_form.body.map { |statement| lower_statement(statement) }
      leave_loop_scopes(break_tag, next_tag)
      body = [catch_wrap(next_tag, body)] if next_tag
      dotimes_form = Elisp.list(
        Elisp.symbol("dotimes"),
        Elisp.list(
          Elisp.symbol(times_form.parameter),
          lower_expression(times_form.count)
        ),
        *body
      )
      break_tag ? catch_wrap(break_tag, [dotimes_form]) : dotimes_form
    end

    # Shared lowering for `.each` and the iteration forms: enters the loop
    # tag scopes, lowers the block body into a lambda (catching `next` per
    # invocation when the body uses it), yields the lambda to build the
    # call, and wraps the call in the break catch when the body uses it.
    def lower_block_iteration(form)
      break_tag, next_tag = enter_loop_scopes(form.body)
      lambda_body = form.body.map { |statement| lower_statement(statement) }
      leave_loop_scopes(break_tag, next_tag)
      lambda_body = [catch_wrap(next_tag, lambda_body)] if next_tag
      lambda_form = Elisp.list(
        Elisp.symbol("lambda"),
        Elisp.inline_list(Elisp.symbol(form.parameter)),
        *lambda_body
      )
      call_form = yield lambda_form
      break_tag ? catch_wrap(break_tag, [call_form]) : call_form
    end

    def enter_loop_scopes(body)
      break_tag = allocate_loop_tag(body, Forms::Break, "break")
      next_tag = allocate_loop_tag(body, Forms::Next, "next")
      @break_tags.push(break_tag) if break_tag
      @next_tags.push(next_tag) if next_tag
      [break_tag, next_tag]
    end

    def allocate_loop_tag(body, klass, kind)
      body_has_exit?(body, klass, LOOP_EXIT_BOUNDARIES) ? allocate_tag(kind) : nil
    end

    def leave_loop_scopes(break_tag, next_tag)
      @break_tags.pop if break_tag
      @next_tags.pop if next_tag
    end

    def lower_branch(statements)
      return Elisp.symbol("nil") if statements.empty?

      forms = statements.map { |statement| lower_statement(statement) }
      return forms.first if forms.one?

      Elisp.list(Elisp.symbol("progn"), *forms)
    end

    def lower_literal(literal)
      case literal.kind
      when :string then Elisp.string(literal.value)
      when :integer then Elisp.integer(literal.value)
      when :float then Elisp.float(literal.value)
      when :true then Elisp.symbol("t")
      when :false, :nil then Elisp.symbol("nil")
      when :symbol then Elisp.quote(Elisp.symbol(literal.value))
      else
        raise ArgumentError, "cannot lower Ruri literal kind: #{literal.kind.inspect}"
      end
    end
  end
end
