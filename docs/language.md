# Ruri language contract — version 0.9

Ruri (瑠璃) is Ruby-shaped scripting for Emacs. A `.ruri` source file is a
Ruby-syntax DSL that compiles to an ordinary, dependency-free Emacs Lisp
file. Ruby syntax is the contract; the Ruby runtime is not. This document
is the exact scope of version 0.9: every construct below is supported,
everything else is rejected with a source position.

## Pipeline

```
.ruri source → Prism parse → validation → typed Ruri forms → generic Elisp AST → .el text
```

- The whole input is parsed and validated before anything is emitted. A
  file with one valid command and one invalid line produces no output.
- The compiler never evaluates Ruby input: no `eval`, `load`,
  `instance_eval`, or any other execution of source text. The Prism AST is
  matched structurally, lowered into generic Elisp nodes, and serialized by a
  deterministic S-expression printer. Raw strings cannot be inserted into
  lists, so string literals can never become additional Lisp forms.
- Generated files begin with `;;; -*- lexical-binding: t; -*-`, identify
  the `.ruri` file they were generated from, and have no runtime
  dependency on Ruby, the compiler, or any Emacs helper package.

## Supported constructs

| Source construct | Meaning and restriction |
| --- | --- |
| `command :hello_buffer do … end` | Top-level command definition; emits `(defun hello-buffer () …)`. Exactly one literal symbol argument, no parameters, no receiver, no block parameters, no nested commands. Multiple distinct commands per file are allowed. |
| `function :decorate do \|value\| … end` | Top-level noninteractive function definition; emits `(defun decorate (ruri--local-value) …)`. Zero or more required positional parameters are accepted. The final expression is the return value. |
| `doc "…"` | Documentation string. Exactly once, as the first statement of a `command` or `function` body; emits a defun docstring on its own line. `interactive`, when present, follows it. |
| `variable :name [, value] [, "doc"]` | Emits `(defvar name [value] ["doc"])`. The value is any supported expression and may be omitted; the docstring is an optional literal string. |
| `constant :name, value [, "doc"]` | Emits `(defconst name value ["doc"])`. The value is required. |
| `custom :name, value [, "doc"] [, type: expression]` | Emits `(defcustom name value ["doc"] [:type expr])`. The optional `type:` expression lowers like any expression, so `type: :string` emits `:type 'string` and richer types use quote/quasiquote data. |
| `require :name`, `provide :name` | Top-level only; emit `(require 'name)` and `(provide 'name)`, keeping source order among definitions. |
| `interactive` | Emits `(interactive)`. Exactly once in each command body, directly after the optional docstring; no arguments, no block. |
| `with_current_buffer("*scratch*") do … end` | Emits `(with-current-buffer "*scratch*" …)`. Exactly one literal string argument, nonempty block, no block parameters. Valid inside a command body or nested inside another buffer block. Uses an existing buffer and preserves normal Emacs missing-buffer errors. |
| `insert("text")` | Emits `(insert "text")`. Exactly one literal string argument, no block. Valid inside a command body or a buffer block. |
| `el.message("value: %s", el.buffer_name)` | Calls an Emacs Lisp function through the explicit `el` namespace. Calls may be statements or nested expressions. Arguments are recursively parsed expressions. Keyword arguments are rejected. |
| `el.save_excursion do … end` | Emits an Elisp form with the Ruby block appended as body forms: `(save-excursion …)`. Positional arguments, nested statements, locals, and conditionals compose inside the body. Block parameters are rejected. |
| `name = el.buffer_name` | Assigns a definition-local variable. The right-hand side may be any supported expression. A local is visible throughout its command or function, including before its first assignment (where its value is `nil`) and inside nested blocks. Compound assignments are rejected. |
| `if condition … elsif condition … else … end` | Evaluates supported expression conditions with Emacs Lisp truth semantics. Branches contain ordinary supported statements. `elsif` and `else` are optional. |
| `unless condition … else … end` | The negated conditional form. The `else` branch is optional. |
| `fn do \|value\| … end` | Creates a lexical lambda: `(lambda (ruri--local-value) …)`. Zero or more required positional parameters are accepted. The body uses normal Ruri statements and may capture surrounding locals. |
| `function(:buffer_name)` | Creates the named function value `(function buffer-name)`. The literal symbol is normalized from snake_case to kebab-case. |
| `list(1, :two)` | Constructs an evaluated Lisp list: `(list 1 'two)`. Unlike Ruby array syntax, this produces a list rather than a vector. |
| `cons(:key, value)` | Constructs one cons cell: `(cons 'key ruri--local-value)`. Exactly two evaluated arguments are required. |
| `quote(list(:a, :b))` | Emits literal data using reader quote syntax: `'(a b)`. Quoted data accepts literals, arrays, `list`, and `cons`; runtime expressions are rejected. |
| `quasiquote(list(:a, unquote(value), splice(items)))` | Emits a backquoted template: `` `(a ,value ,@items) ``. `splice` is valid only within a quasiquoted list or vector. |
| `left && right`, `left \|\| right`, `!value` | Short-circuit boolean operations lowered to `and`, `or`, and `not`. Parentheses may group expressions. |
| `a == b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b` | Equality uses Elisp `equal`; inequality wraps it in `not`. Ordered comparisons use their corresponding Elisp numeric forms. |
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b`, `a ** b`, `-a`, `+a` | Arithmetic lowered to `+`, `-`, `*`, `/`, `mod`, `expt`, unary `-`, and `identity`. Operand and division behavior follows Emacs Lisp. |
| `while condition … end`, `until condition … end` | Repeatedly executes the body. `until` lowers to `while` with a negated condition. |
| `items.each do \|item\| … end` | Iterates for side effects using `mapc` and a lexical lambda. Exactly one required block parameter is allowed. The collection may be any supported expression. |
| Comments and whitespace | Accepted according to Ruby syntax (`#` line comments, `=begin`/`=end` block comments); no effect on semantics. |

## Emacs Lisp calls

- Only calls with the literal receiver `el` enter the generic call path.
  `el.message("hello")` emits `(message "hello")`; ordinary Ruby-shaped calls
  such as `message("hello")` and other receivers remain compile errors.
- Function names must use lowercase Ruby method syntax. Underscores become
  hyphens, while a trailing `?` or `!` is preserved: `el.buffer_live?` emits
  `buffer-live?`.
- Zero-argument calls idiomatically omit parentheses: `el.buffer_name` emits
  `(buffer-name)`. An explicit empty pair, `el.buffer_name()`, remains accepted
  and has identical semantics.
- Positional arguments may contain any supported expression, including another
  `el.*` call. An optional block is lowered to trailing body forms. This makes
  body-oriented macros such as `save-excursion`, `progn`, and
  `with-temp-buffer` available without compiler-specific wrappers.
- A generic block is Elisp form structure, not a Ruby closure or callback. It
  takes no block parameters. Ruri deliberately does not validate whether the
  target function, macro, or special form accepts a body.
- Generic calls do not accept keyword arguments, splats, safe navigation, or
  assignment methods.
- Ruri does not keep an Emacs function catalogue or enforce arity. The Emacs
  byte compiler and runtime report unknown functions and invalid arguments.

## Expressions

Expressions are allowed as assignment values, conditional predicates,
arguments to `el.*` calls, and final values in functions and lambdas.

| Ruby expression | Emacs Lisp output | Meaning |
| --- | --- | --- |
| `"text"`, `'text'` | `"text"` | Ruby-decoded UTF-8 string |
| `42`, `-7` | `42`, `-7` | Integer |
| `1.5`, `-0.25` | `1.5`, `-0.25` | Finite float |
| `true` | `t` | True |
| `false`, `nil` | `nil` | Emacs has one false/empty-list value, so these intentionally collapse |
| `:after_save_hook` | `'after-save-hook` | Quoted Elisp symbol; underscores become hyphens |
| `[1, :two, el.point]` | `(vector 1 'two (point))` | Vector whose elements are evaluated in order |
| `name` | `ruri--local-name` | Reference to a parameter or local in the same definition |
| `var :case_fold_search` | `case-fold-search` | Dynamic value of an Emacs Lisp variable; emits the bare symbol, unlike quoted symbol literals |
| `fn do \|value\| … end` | `(lambda (ruri--local-value) …)` | Lexical anonymous function |
| `function(:identity)` | `(function identity)` | Named function value suitable for callbacks |
| `list(1, :two)` | `(list 1 'two)` | Evaluated proper list |
| `cons(:key, value)` | `(cons 'key ruri--local-value)` | Evaluated cons cell |
| `quote(list(:a, :b))` | `'(a b)` | Literal data without evaluation |
| `quasiquote(list(:a, unquote(value)))` | `` `(a ,ruri--local-value) `` | Data template with evaluated positions |
| `a + b`, `a == b`, `a && b` | `(+ a b)`, `(equal a b)`, `(and a b)` | Arithmetic, comparison, and short-circuit logic |

Ruby arrays lower to a call to `vector`, rather than bracket syntax, because an
Emacs vector literal is self-evaluating and would not evaluate nested calls.

### Lisp data

- `list` and `cons` evaluate their elements at runtime. They are explicit Ruri
  expressions so lists stay distinct from Ruby arrays, which represent Emacs
  vectors.
- `quote` accepts one data expression composed from strings, numbers,
  booleans, `nil`, symbols, arrays, `list`, and `cons`. Calls and local reads
  are rejected because quoted positions are not evaluated.
- `quasiquote` accepts the same data grammar and additionally recognizes
  `unquote(expression)` and `splice(expression)`. An unquoted expression is a
  normal Ruri expression. A splice must be an element of a quasiquoted list or
  vector; its runtime value must be a compatible sequence as required by
  Emacs.
- Symbols inside `quote` and `quasiquote` become raw data symbols. Symbols in
  evaluated expressions retain the existing behavior and emit their own quote.
  This prevents nested data from being double quoted.
- Nested `quote` or `quasiquote` forms are reserved for later work. Version 0.8
  supports one template level with any number of unquoted or spliced values.

### Operators and loops

- `&&` and `||` preserve left-to-right short-circuit evaluation and return the
  selected operand according to Elisp `and` and `or` semantics. `!` emits
  `not`.
- `==` compares general Elisp values with `equal`; `!=` is its negation.
  Ordered comparisons and arithmetic use Emacs primitives directly. In
  particular, `/` follows Emacs integer and floating-point division rules;
  string concatenation remains `el.concat(...)`.
- `while` and `until` accept any supported expression as their condition and
  normal Ruri statements in their body. `break`, `next`, and `redo` are not
  yet supported.
- `.each` is the one permitted ordinary explicit receiver form. It is valid as
  a statement, accepts no call arguments, requires exactly one positional
  block parameter, and lowers to `mapc`. Its parameter is hygienic and scoped
  to the block; other surrounding locals are captured and may be mutated.

### Function values

- `fn` takes no call arguments and requires a block. Its block parameters are
  Ruby's ordinary `|name, other|` syntax. Version 0.8 accepts required
  positional parameters only; optional, rest, keyword, and block parameters
  are rejected.
- Lambda parameters use the same hygienic local-name lowering and shadow a
  surrounding local with the same source name. Parameters are visible only
  inside their lambda. Other surrounding locals are captured lexically and
  remain available if Emacs invokes the lambda after the definition returns.
- Assignments inside a lambda keep Ruri's definition-local behavior, which makes
  mutable captured state possible. A lambda parameter assignment mutates that
  invocation's parameter binding.
- `function` requires exactly one literal symbol and no block. It does not
  check that Emacs has defined the named function; byte compilation or runtime
  invocation reports a missing definition.

### Function definitions

- `function :name do |argument| … end` defines a top-level, noninteractive
  Elisp function. It accepts zero or more required positional parameters.
  Optional, rest, keyword, and block parameters are rejected in version 0.8.
- Parameters and assigned locals use hygienic `ruri--local-` names. Assigning
  to a parameter mutates its argument binding; other assigned names are
  initialized in a lexical `let` around the body.
- The final supported expression supplies the return value. A final `if` or
  `unless` applies the same rule to every branch, so the selected branch value
  becomes the result. An omitted branch returns `nil` through normal Elisp
  conditional semantics.
- Recursion and calls to other Ruri definitions use the explicit namespace,
  such as `el.factorial(number - 1)`. `function(:factorial)` creates a named
  function value for callbacks and higher-order calls.
- A function body may be empty, in which case the generated function returns
  `nil`. `interactive` remains exclusive to command definitions.

## Names

- Command and function names must match ASCII `[a-z][a-z0-9_]*` in the source.
- Each `_` becomes `-` in the emitted Emacs Lisp name (`:hello_buffer`
  defines `hello-buffer`).
- Commands and functions share one definition namespace and must not define
  the same name. Because the source grammar excludes hyphens,
  underscore-to-hyphen conversion is one-to-one for valid definition names.
- Variables (`variable`, `constant`, `custom`) live in Emacs Lisp's separate
  variable namespace, so a variable may share a name with a function;
  duplicates within each variable kind are rejected.
- Reloading the same extension may redefine its own definitions normally —
  the duplicate check is per compile unit, not per Emacs session.
- Local names follow the same ASCII source pattern. The compiler emits a
  private `ruri--local-` prefix and replaces underscores with hyphens, so a
  source name such as `case_fold_search` cannot accidentally bind Emacs's
  special `case-fold-search` variable. The name `t` is reserved.
- Every assigned local is initialized to `nil` in one lexical `let` around
  its definition body. Assignments mutate that binding with `setq`; top-level
  definitions do not share locals.

## Strings

- Ordinary Ruby single- and double-quoted string literals are supported
  through Prism's decoded literal value, so Ruby escape semantics
  (`\n`, `\t`, `\\`, `\"`, `\e`, `\u{...}`) work as in Ruby.
- The emitter escapes every character that is special in Emacs Lisp
  string syntax: backslash, double quote, newline, tab, carriage return,
  and other ASCII control characters (emitted as three-digit octal
  escapes). Non-ASCII UTF-8 characters are written literally and the
  output file is UTF-8.
- Rejected in v0.8: string interpolation (`#{…}`), heredocs, character
  literals, and concatenated or adjacent string forms.

## Rejected outright

Everything outside the table above, including but not limited to:

- Ruby instance, class, and global variables; constants; destructuring and
  compound assignments; classes, modules, hashes, ranges, method definitions,
  and standalone literal statements.
- Explicit receivers other than the reserved `el` namespace and supported
  `.each` iteration (`Kernel.insert("x")`, `foo.bar`), safe-navigation,
  unsupported operators, unqualified arbitrary method calls, and
  `lambda`/`proc`.
- Keyword arguments, splats, default parameters, heredocs, and interpolation.
  `fn`, `function`, and `.each` accept the block parameters described above;
  `command`, `with_current_buffer`, and `el.*` accept only parameterless blocks;
  `insert` does not accept a block.
- Executable top-level expressions: a `.ruri` file may contain only
  definitions and declarations — `command`, `function`, `variable`,
  `constant`, `custom`, `require`, and `provide` (plus comments).
- Nested `command` or `function` definitions; `interactive` outside a command body,
  duplicated, or not first; empty `with_current_buffer` blocks;
  `insert` with a block.

Each rejection is a compile error reported as `path:line:column: message`
with 1-based positions pointing at the offending node.

## Example

Source (`examples/hello.ruri`):

```ruby
command :hello_buffer do
  interactive
  with_current_buffer("*scratch*") do
    insert("Hello from Ruby syntax!\n")
  end
end
```

Generated Lisp (`examples/hello.el`):

```elisp
;;; -*- lexical-binding: t; -*-
(defun hello-buffer ()
  (interactive)
  (with-current-buffer "*scratch*"
    (insert "Hello from Ruby syntax!\n")))
```

## Reserved for later versions

Optional and rest function or lambda parameters, command parameters and
interactive specifications, nested quasiquotation, loop exits, and a raw Lisp
escape hatch remain out of scope.

## Path toward broad Elisp coverage

Ruri aims to cover practical Emacs Lisp source programs, rather than duplicate
the reader syntax or bytecode format one token at a time. Generic `el.*` calls
and body forms provide the open-ended function, macro, and special-form layer.
The remaining language work is primarily about representing values and lexical
structure safely:

1. Optional and rest parameters for functions and lambdas; v0.8 provides
   top-level noninteractive functions, value returns, recursion, function
   references, lexical lambdas, captures, and required positional parameters.
2. Nested quasiquotation and richer reader data; v0.6 provides evaluated
   lists and cons cells, literal quote, and single-level quasiquote with
   unquote and splicing.
3. Broader iteration, loop exits, and assignment operators; v0.7 provides
   boolean, comparison, arithmetic, `while`, `until`, and side-effecting
   `.each` syntax.
4. Command argument lists and interactive specifications.
5. Variable and package structure; v0.9 provides `variable`, `constant`,
   `custom` (with `type:`), `require`, and `provide`, documentation strings
   for commands and functions, and `var` reads of dynamic Elisp variables.
6. Error handling and nonlocal exits (`condition-case`, `unwind-protect`,
   `catch`, `throw`) remain future work.

Some Elisp facilities will remain available through explicit `el.*` forms
instead of receiving dedicated Ruby syntax. That keeps Ruri small while still
allowing the generated program to use the wider Emacs API.
