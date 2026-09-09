# frozen_string_literal: true

module Ruri
  # Validated internal representation of a .ruri source file. The parser
  # produces these from the Prism AST; the emitter is the only component
  # that turns them into text, so string values can never leak into the
  # output as Lisp structure.
  module Forms
    # Top-level command definition.
    # +source_name+ is the symbol as written; +name+ is the Emacs Lisp
    # name after `_` -> `-` conversion.
    Command = Data.define(:source_name, :name, :body)

    # The required first statement of every command body.
    Interactive = Data.define

    # Buffer-scoped block: body statements run inside the named buffer.
    WithCurrentBuffer = Data.define(:buffer, :body)

    # Insert text at point in the current buffer.
    Insert = Data.define(:text)
  end
end
