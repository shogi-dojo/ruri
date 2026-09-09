# frozen_string_literal: true

module Ruri
  # Converts validated, language-level Forms into a generic Emacs Lisp AST.
  # This is the only component that knows how a Ruri construct maps to Lisp.
  class Lowerer
    class << self
      def lower(commands)
        new.lower(commands)
      end
    end

    def lower(commands)
      commands.map { |command| lower_command(command) }
    end

    private

    def lower_command(command)
      body = command.body.map { |statement| lower_statement(statement) }
      locals = collect_locals(command.body)
      unless locals.empty?
        interactive, *statements = body
        scope = Elisp.list(
          Elisp.symbol("let"),
          Elisp.inline_list(*locals.map { |name| Elisp.symbol(name) }),
          *statements
        )
        body = [interactive, scope]
      end

      Elisp.list(
        Elisp.symbol("defun"),
        Elisp.symbol(command.name),
        Elisp.inline_list,
        *body
      )
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
        when Forms::Call
          collect_expression_locals(statement, names, shadowed)
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
        collect_locals(expression.body, names, shadowed + expression.parameters)
      when Forms::QuasiQuote
        collect_template_locals(expression.value, names, shadowed)
      when Forms::Operation
        expression.arguments.each do |argument|
          collect_expression_locals(argument, names, shadowed)
        end
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
        Elisp.list(Elisp.symbol("interactive"))
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
      when Forms::Lambda
        Elisp.list(
          Elisp.symbol("lambda"),
          Elisp.inline_list(*expression.parameters.map { |name| Elisp.symbol(name) }),
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
      else
        raise ArgumentError, "cannot lower Ruri expression: #{expression.class}"
      end
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
