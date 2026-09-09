# frozen_string_literal: true

module Ruri
  # Validated internal representation of a .ruri source file. The parser
  # produces these from the Prism AST; the lowerer converts them to generic
  # Elisp nodes, so source values never become output structure directly.
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

    # An explicit call through the `el' namespace. Arguments are expression
    # forms, an optional Ruby block becomes trailing Elisp body forms, and
    # +name+ is already normalized from snake_case to kebab-case.
    Call = Data.define(:name, :arguments, :body)

    # Scalar expression value. Supported kinds are :string, :integer, :float,
    # :true, :false, :nil, and :symbol.
    Literal = Data.define(:kind, :value)

    # Ruby array syntax denotes an Emacs Lisp vector value.
    Vector = Data.define(:elements)

    # First-class function values. Lambda parameters are hygienic Elisp names;
    # a named reference lowers to (function NAME) without quoting NAME as data.
    Lambda = Data.define(:parameters, :body)
    FunctionReference = Data.define(:source_name, :name)

    # Lisp data constructors and template forms.
    ListValue = Data.define(:elements)
    ConsValue = Data.define(:car, :cdr)
    Quote = Data.define(:value)
    QuasiQuote = Data.define(:value)
    Unquote = Data.define(:value)
    Splice = Data.define(:value)

    # Ruby operators retain their evaluation shape while using Elisp runtime
    # semantics. +negated+ represents != without inventing another primitive.
    Operation = Data.define(:name, :arguments, :negated)

    # A hygienically renamed lexical variable assignment and reference.
    LocalWrite = Data.define(:source_name, :name, :value)
    LocalRead = Data.define(:source_name, :name)

    # Ruby if/unless statement. Unless uses +negated+ so lowering needs only
    # one conditional representation. Branches contain ordinary statements.
    Conditional = Data.define(:condition, :then_body, :else_body, :negated)
    Loop = Data.define(:condition, :body, :negated)
    Each = Data.define(:collection, :parameter, :body)
  end
end
