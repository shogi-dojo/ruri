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
      lowered_rest = rest.map { |statement| lower_statement(statement) }
      locals = collect_locals(rest)
      lowered_rest = wrap_locals(locals, lowered_rest) unless locals.empty?
      lowered_rest = lower_parameter_defaults(command.parameters) + lowered_rest

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
      lowered = statements.map { |statement| lower_statement(statement) }
      locals = collect_locals(statements, [], function.parameters.names)
      lowered = wrap_locals(locals, lowered) unless locals.empty?
      lowered = lower_parameter_defaults(function.parameters) + lowered

      Elisp.list(
        Elisp.symbol("defun"),
        Elisp.symbol(function.name),
        lower_parameter_list(function.parameters),
        *doc_form,
        *lowered
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
      end
    end

    def collect_template_locals(value, names, shadowed)
      case value
      when Forms::Unquote, Forms::Splice
        collect_expression_locals(value.value, names, shadowed)
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
        Elisp.list(
          Elisp.symbol("mapc"),
          Elisp.list(
            Elisp.symbol("lambda"),
            Elisp.inline_list(Elisp.symbol(statement.parameter)),
            *statement.body.map { |child| lower_statement(child) }
          ),
          lower_expression(statement.collection)
        )
      when Forms::Rescue
        lower_rescue(statement)
      when Forms::Ensure
        lower_ensure(statement)
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
        Elisp.list(
          Elisp.symbol("lambda"),
          lower_parameter_list(expression.parameters),
          *lower_parameter_defaults(expression.parameters),
          *expression.body.map { |statement| lower_statement(statement) }
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
      else
        raise ArgumentError, "cannot lower Ruri expression: #{expression.class}"
      end
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
      when Forms::Unquote
        Elisp.unquote(lower_expression(value.value))
      when Forms::Splice
        Elisp.splice(lower_expression(value.value))
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

    def lower_loop(loop)
      condition = lower_expression(loop.condition)
      condition = Elisp.list(Elisp.symbol("not"), condition) if loop.negated
      Elisp.list(
        Elisp.symbol("while"),
        condition,
        *loop.body.map { |statement| lower_statement(statement) }
      )
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
