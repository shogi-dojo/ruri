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
      Elisp.list(
        Elisp.symbol("defun"),
        Elisp.symbol(command.name),
        Elisp.list,
        *command.body.map { |statement| lower_statement(statement) }
      )
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
      else
        raise ArgumentError, "cannot lower Ruri form: #{statement.class}"
      end
    end

    def lower_call(call)
      Elisp.list(
        Elisp.symbol(call.name),
        *call.arguments.map { |argument| lower_expression(argument) }
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
      else
        raise ArgumentError, "cannot lower Ruri expression: #{expression.class}"
      end
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
