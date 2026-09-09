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
      when Forms::Lambda
        collect_locals(expression.body, names, shadowed + expression.parameters)
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
      else
        raise ArgumentError, "cannot lower Ruri expression: #{expression.class}"
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
