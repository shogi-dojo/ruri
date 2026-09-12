# frozen_string_literal: true

module Ruri
  # Validated internal representation of a .ruri source file. The parser
  # produces these from the Prism AST; the lowerer converts them to generic
  # Elisp nodes, so source values never become output structure directly.
  module Forms
    # An `&optional` parameter. +name+ is the hygienic Elisp argument name
    # and +default+ is the parsed entry-time default expression, or nil for
    # plain Elisp nil-defaulting.
    OptionalParameter = Data.define(:name, :default)
    # An `&rest` parameter collecting remaining arguments under +name+.
    RestParameter = Data.define(:name)
    # Parameter list for functions, lambdas, and commands. +required+ is an
    # array of hygienic names; +rest+ is a RestParameter or nil.
    ParameterList = Data.define(:required, :optionals, :rest) do
      def names
        required + optionals.map(&:name) + (rest ? [rest.name] : [])
      end

      def empty?
        required.empty? && optionals.empty? && rest.nil?
      end
    end

    # Top-level command definition.
    # +source_name+ is the symbol as written; +name+ is the Emacs Lisp
    # name after `_` -> `-` conversion.
    Command = Data.define(:source_name, :name, :parameters, :body)
    # Top-level noninteractive function with hygienic parameters.
    FunctionDefinition = Data.define(:source_name, :name, :parameters, :body)

    # Top-level variable definitions. +value+ is nil for a valueless
    # defvar; +docstring+ is an optional source string.
    VariableDefinition = Data.define(:source_name, :name, :value, :docstring)
    ConstantDefinition = Data.define(:source_name, :name, :value, :docstring)

    # Top-level customizable variable. +type+ is an optional expression
    # lowered after the :type keyword.
    CustomDefinition = Data.define(:source_name, :name, :value, :docstring, :keywords)

    # Top-level buffer-local variable definition (defvar-local).
    VariableLocalDefinition = Data.define(:source_name, :name, :value, :docstring)

    # Statement form assigning to Emacs Lisp variables (setq). Pairs are
    # [name, value_expression] in source order.
    Assign = Data.define(:pairs)

    # Elisp keyword symbol (:begin, :end), self-quoting in Elisp.
    Keyword = Data.define(:source_name, :name)

    # Top-level feature declarations: (require 'name) / (provide 'name).
    Require = Data.define(:source_name, :name)
    Provide = Data.define(:source_name, :name)

    # Reading the dynamic value of an Emacs Lisp variable.
    VarRead = Data.define(:source_name, :name)

    # The required first statement of every command body. +spec+ is the
    # optional interactive specification: a string-literal expression form
    # (as Emacs reads it, e.g. "P" for the raw prefix argument), or nil for
    # a plain `(interactive)`.
    Interactive = Data.define(:spec)

    # Documentation string. Only valid as the first statement of a command
    # or function body; lowers to a dedicated Elisp docstring node.
    Docstring = Data.define(:text)

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

    # First-class function values. Lambda parameters are a hygienic
    # ParameterList; a named reference lowers to (function NAME) without
    # quoting NAME as data.
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

    # Value-producing iteration: `.map` → mapcar, `.select` → seq-filter
    # (needs `require :seq` in the source), `.find` → seq-find (likewise).
    # The block's final expression maps the element. Kept distinct from
    # side-effecting `.each`, which lowers to mapc.
    Iteration = Data.define(:name, :collection, :parameter, :body)

    # Scoped bindings: `let do |a = 1, b = a + 1, c| … end`. +parameters+
    # is a hygienic ParameterList whose rest slot is always nil (rejected
    # by the parser). Initializers were parsed left to right, so each may
    # read the bindings before it; lowering emits `let*`, and a parameter
    # without a default binds nil. The body's final form supplies the
    # value, and the bindings are visible only inside the block.
    Let = Data.define(:parameters, :body)

    # `begin/rescue[/else]` lowered to condition-case. +var+ is the hygienic
    # error-object binding shared by every clause, or nil. +clauses+ are
    # [conditions, body] pairs in source order; +conditions+ is a nonempty
    # list of Elisp condition-name symbols (a bare rescue maps to `error`).
    # +else_body+ runs, and supplies the value, when the body raises nothing.
    Rescue = Data.define(:var, :clauses, :else_body, :body)
    # `begin/ensure` lowered to unwind-protect. +body+ holds the protected
    # forms (a lone Rescue form when both clauses are present); the
    # unwound value is the body's value, never the cleanup's.
    Ensure = Data.define(:body, :ensure_body)

    # `catch(:tag) do … end` and `throw :tag, value`. The tag is an
    # unevaluated Elisp symbol that thrown values cross, so both are typed
    # forms rather than el.* calls (which would quote the tag wrongly).
    Catch = Data.define(:tag, :body)
    Throw = Data.define(:tag, :value)

    # Loop exits and definition returns. All three lower to throws against
    # compiler-generated catch tags: `break`/`next` target their enclosing
    # loop, `return` targets the innermost definition body. +value+ is the
    # optional carried expression; a bare exit throws nil.
    Break = Data.define(:value)
    Next = Data.define(:value)
    Return = Data.define(:value)
    # Preserves an expression used for its value as a body form.
    ExpressionStatement = Data.define(:expression)
  end
end
