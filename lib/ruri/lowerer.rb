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
      else
        raise ArgumentError, "cannot lower Ruri form: #{statement.class}"
      end
    end
  end
end
