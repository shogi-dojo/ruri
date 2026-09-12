# Ruri language contract — version 0.12

Ruri (瑠璃) is Ruby-shaped scripting for Emacs. A `.ruri` source file is a
Ruby-syntax DSL that compiles to an ordinary, dependency-free Emacs Lisp
file. Ruby syntax is the contract; the Ruby runtime is not. This document
is the exact scope of version 0.12: every construct below is supported,
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
| `command :hello_buffer do \|arg\| … end` | Top-level command definition; emits `(defun hello-buffer (ruri--local-arg) …)`. Exactly one literal symbol argument and no receiver; block parameters follow the function parameter rules (required, optional with defaults, rest). No nested commands. Multiple distinct commands per file are allowed. |
| `function :decorate do \|value\| … end` | Top-level noninteractive function definition; emits `(defun decorate (ruri--local-value) …)`. Required, optional, and rest positional parameters are accepted (see Function definitions). The final expression is the return value. |
| `doc "…"` | Documentation string. Exactly once, as the first statement of a `command` or `function` body; emits a defun docstring on its own line. `interactive`, when present, follows it. |
| `variable :name [, value] [, "doc"]` | Emits `(defvar name [value] ["doc"])`. The value is any supported expression and may be omitted; the docstring is an optional literal string. |
| `constant :name, value [, "doc"]` | Emits `(defconst name value ["doc"])`. The value is required. |
| `custom :name, value [, "doc"] [, key: expression …]` | Emits `(defcustom name value ["doc"] [:key expr …])`. Any keyword pairs are accepted and rendered as `:key value` in source order, so standard keywords such as `group:`, `type:`, and `options:` work directly. Each value lowers like any expression, so `type: :string` emits `:type 'string` and richer types use quote/quasiquote data. Keyword names must match `[a-z][a-z0-9_]*` and are normalized from snake_case to kebab-case. |
| `variable_local :name [, value] [, "doc"]` | Emits `(defvar-local name [value] ["doc"])`, declaring a variable that becomes buffer-local whenever it is set. Accepts the same arguments as `variable`. |
| `require :name`, `provide :name` | Top-level only; emit `(require 'name)` and `(provide 'name)`, keeping source order among definitions. |
| `interactive "P"` | Emits `(interactive "P")`, or plain `(interactive)` without an argument. Exactly once in each command body, directly after the optional docstring. The spec is at most one literal string, read by Emacs at invocation time (`"P"` raw prefix, `"p"` numeric prefix, `"r"` region, `"sPrompt: "` string, and so on); no block. The spec is never evaluated as Ruri code. |
| `begin … rescue [:cond, …] [=> var] … else … end` | Lowers to `condition-case`. Conditions are literal symbols normalized to Elisp condition names (`:arith_error` → `arith-error`); a bare `rescue` catches the `error` condition. Every clause may bind the same optional `=> var` — one binding, hygienic like other locals, readable in the handlers and (matching Ruby) after the block. `else` becomes a `(:success …)` handler whose value wins when nothing is raised. Valid as a statement or as the final value of a definition. |
| `begin … [rescue …] ensure … end` | The `ensure` clause lowers to `unwind-protect`: cleanup always runs — including on the error path — and the result is the body's (or handler's) value, never the cleanup's. With both clauses the rescue form nests inside the ensure form. |
| `catch(:tag) do … end`, `throw :tag, value` | Nonlocal exits with quoted symbol tags: `(catch 'tag …)` and `(throw 'tag value)`. The tag is an unevaluated literal symbol; the catch returns the thrown value, or its last body form's value when nothing is thrown. Throws may cross loops, `condition-case`, and cleanup forms. |
| `let do \|a = 1, b = a + 1, c\| … end` | Scoped bindings lowering to `let*` with hygienic names. Initializers are evaluated left to right, so each may read the bindings to its left — exactly Ruby's own parameter-default semantics; a binding whose initializer reads its own name sees the outer binding, and a forward reference to a later binding is rejected as an undefined local. A parameter without a default (or with a literal `nil`/`false` one) binds `nil`. The bindings are visible only inside the block, shadow outer locals of the same name, and assignments to them mutate the binding; the block's final form supplies its value. `break` and `next` may not cross a `let` block; `return` passes through to the enclosing definition. No call arguments, no rest parameter. |
| `with_current_buffer("*scratch*") do … end` | Emits `(with-current-buffer "*scratch*" …)`. Exactly one literal string argument, nonempty block, no block parameters. Valid inside a command body or nested inside another buffer block. Uses an existing buffer and preserves normal Emacs missing-buffer errors. |
| `insert("text")` | Emits `(insert "text")`. Exactly one literal string argument, no block. Valid inside a command body or a buffer block. |
| `el.message("value: %s", el.buffer_name)` | Calls an Emacs Lisp function through the explicit `el` namespace. Calls may be statements or nested expressions. Arguments are recursively parsed expressions. Keyword arguments are rejected. |
| `el.setf(place, value)`, `el.push(value, place)`, `el.pop(place)`, `el.cl_incf(place [, delta])`, `el.cl_decf(place [, delta])` | Generalized-place assignment as typed forms: the place sits in an unevaluated position, so a place is an Elisp variable symbol (`:name`), a Ruri local, `var(:name)`, or an `el.*` form such as `el.car(x)`. `push` keeps Elisp argument order — value first, place last. Anything else in the place position is rejected at compile time. `setf` takes exactly one place and one value (multiple pairs are not supported); `pop` exactly one place. |
| `el.save_excursion do … end` | Emits an Elisp form with the Ruby block appended as body forms: `(save-excursion …)`. Positional arguments, nested statements, locals, and conditionals compose inside the body. Block parameters are rejected. |
| `name = el.buffer_name` | Assigns a definition-local variable. The right-hand side may be any supported expression. A local is visible throughout its command or function, including before its first assignment (where its value is `nil`) and inside nested blocks. Compound assignments are rejected. |
| `var(:fill_column)` | Reads an Emacs Lisp (dynamic, global, or buffer-local) variable, emitting the bare symbol `fill-column`. Definition-locals are referenced by their Ruby name instead. Exactly one literal symbol argument matching `[a-z][a-z0-9_]*`; `t` and `nil` are rejected. |
| `assign :name, value [, :name2, value2 …]` | Emits `(setq name value …)`, writing an Emacs Lisp (dynamic or buffer-local) variable rather than a definition-local. Variable names are literal symbols in unevaluated position, so this is a typed form rather than an `el.setq` call, which would wrongly quote the symbol. Requires an even number of arguments; every odd position must be a literal symbol matching `[a-z][a-z0-9_]*`. |
| `keyword :begin` | Emits the self-quoting Elisp keyword `:begin`. A plain symbol literal would emit `(quote begin)`, which is the wrong shape where keywords are expected, such as `org-element-property` arguments. Exactly one literal symbol argument matching `[a-z][a-z0-9_]*`. |
| `if condition … elsif condition … else … end` | Evaluates supported expression conditions with Emacs Lisp truth semantics. Branches contain ordinary supported statements. `elsif` and `else` are optional. |
| `unless condition … else … end` | The negated conditional form. The `else` branch is optional. |
| `fn do \|value\| … end` | Creates a lexical lambda: `(lambda (ruri--local-value) …)`. Required, optional, and rest positional parameters are accepted (see Function definitions). The body uses normal Ruri statements and may capture surrounding locals. |
| `function(:buffer_name)` | Creates the named function value `(function buffer-name)`. The literal symbol is normalized from snake_case to kebab-case. |
| `list(1, :two)` | Constructs an evaluated Lisp list: `(list 1 'two)`. Unlike Ruby array syntax, this produces a list rather than a vector. |
| `cons(:key, value)` | Constructs one cons cell: `(cons 'key ruri--local-value)`. Exactly two evaluated arguments are required. |
| `quote(list(:a, :b))` | Emits literal data using reader quote syntax: `'(a b)`. Quoted data accepts literals, arrays, `list`, and `cons`; runtime expressions are rejected. |
| `quasiquote(list(:a, unquote(value), splice(items)))` | Emits a backquoted template: `` `(a ,value ,@items) ``. `splice` is valid only within a quasiquoted list or vector. Templates nest; a deeper `unquote` escapes exactly one level (see Lisp data). |
| `left && right`, `left \|\| right`, `!value` | Short-circuit boolean operations lowered to `and`, `or`, and `not`. Parentheses may group expressions. |
| `a == b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b` | Equality uses Elisp `equal`; inequality wraps it in `not`. Ordered comparisons use their corresponding Elisp numeric forms. |
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b`, `a ** b`, `-a`, `+a` | Arithmetic lowered to `+`, `-`, `*`, `/`, `mod`, `expt`, unary `-`, and `identity`. Operand and division behavior follows Emacs Lisp. |
| `while condition … end`, `until condition … end` | Repeatedly executes the body. `until` lowers to `while` with a negated condition. |
| `items.each do \|item\| … end` | Iterates for side effects using `mapc` and a lexical lambda. Exactly one required block parameter is allowed. The collection may be any supported expression. |
| `count.times do \|i\| … end` | Counting loop lowering to `dotimes` with a hygienic counter: `(dotimes (ruri--local-i count) …)`. Exactly one required block parameter, no call arguments; valid as a statement only, and its value is `nil` (matching `dotimes`, not Ruby's `Integer#times`). The counter starts at 0 and the body may use `break`/`next`. |
| `items.map do \|item\| … end`, `items.select do \|item\| … end`, `items.find do \|item\| … end` | Value-producing iteration lowering to `mapcar`, `seq-filter`, and `seq-find`. The block's final expression maps, keeps, or tests each element. Exactly one required block parameter; `select` and `find` require `require :seq` in the source file. |
| `break [value]`, `next [value]` | Exits the enclosing `while`, `until`, `.each`, `.map`, `.select`, or `.find` block through a compiler-generated catch tag: `next` ends one iteration (its value is that element's result in the iteration forms), `break` unwinds the whole loop with the value as its result. Must sit inside the loop, not across an `fn` boundary. Loops without exits emit no extra code. |
| `return [value]` | Returns from the innermost enclosing `command`, `function`, or `fn` body — a `fn` captures its own `return`, matching Ruby lambda semantics. Implemented with a catch tag wrapped around that body only when a `return` is present. |
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
- Calls whose arguments live in unevaluated positions — binding lists,
  patterns, or variable names — cannot pass through the generic path (the
  arguments would be emitted as evaluated calls and fail only at runtime),
  so they are rejected at compile time with a pointer to the typed form
  that covers them: `el.let`/`el.let_star` (use `let`), `el.setq`
  (use `assign`), `el.dolist`/`el.cl_dolist` (use `.each`), `el.dotimes`
  and `el.cl_dotimes` (use `.times`), `el.pcase`, `el.cl_loop`,
  `el.cl_destructuring_bind`, `el.seq_let`, `el.when_let`, and
  `el.if_let` (no Ruri equivalent; rejected outright). The place-taking
  operators `el.setf`, `el.push`, `el.pop`, `el.cl_incf`, and `el.cl_decf`
  are supported as typed forms (see the construct table).

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
- Nested quasiquotation is supported with Common Lisp depth semantics,
  which Emacs follows: a `quasiquote` inside a template opens a template one
  level deeper, and an `unquote` at template depth N escapes exactly one
  level. At depth 1 the escape content is an ordinary runtime expression;
  at deeper levels the content is still quoted data — `unquote(:name)`
  keeps the symbol for the inner template's own evaluation, while
  `unquote(unquote(expression))` (the double escape) evaluates the
  expression at the outer level and keeps one comma for the inner
  evaluation. Splices obey the same depth rules and must remain inside a
  list or vector. `quote` inside a quasiquote stays rejected.

### Operators and loops

- `&&` and `||` preserve left-to-right short-circuit evaluation and return the
  selected operand according to Elisp `and` and `or` semantics. `!` emits
  `not`.
- `==` compares general Elisp values with `equal`; `!=` is its negation.
  Ordered comparisons and arithmetic use Emacs primitives directly. In
  particular, `/` follows Emacs integer and floating-point division rules;
  string concatenation remains `el.concat(...)`.
- `while` and `until` accept any supported expression as their condition and
  normal Ruri statements in their body. `break` and `next` are allowed in
  the body and lower to throws against compiler-generated catch tags;
  `redo` remains rejected.
- `.each` is the one permitted ordinary explicit receiver form for
  side-effecting iteration. It is valid as a statement, accepts no call
  arguments, requires exactly one positional block parameter, and lowers to
  `mapc`. Its parameter is hygienic and scoped to the block; other
  surrounding locals are captured and may be mutated. `.map`, `.select`,
  and `.find` are the value-producing counterparts; see the construct table.

### Function values

- `fn` takes no call arguments and requires a block. Its block parameters are
  Ruby's ordinary `|name, other|` syntax and follow the parameter rules
  described in Parameters (required, optional with defaults, rest).
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

### Parameters

- Block parameters of `function`, `command`, and `fn` accept required
  positionals, optionals with defaults (`|a, scale = 2|`), and one trailing
  rest (`|first, *more|`). They are emitted as Elisp `&optional` and
  `&rest` sections in binding order.
- Elisp plain `defun` arguments have no per-argument default expression, so
  an optional with a default lowers to an entry-time
  `(unless name (setq name default))` emitted after the docstring (and after
  `interactive` in a command), before the body. A literal `nil` or `false`
  default emits no code, because that is already Elisp's own behavior.
- Defaults are therefore applied by nil-collision: the default runs
  whenever the argument is nil at entry, including when the caller passes
  nil explicitly. This is the standard plain-`defun` idiom and is
  documented behavior, not a bug.
- A default expression is parsed with every parameter in scope, so it may
  reference any parameter (for example `|width, fallback = width|`); body
  locals do not exist yet at entry time and cannot appear in defaults.
  Ruby's own grammar applies to defaults, since they are written as block
  parameter defaults.
- Keyword parameters (`|a, key: 1|`), block parameters (`|a, &b|`),
  destructured parameters (`|(a, b)|`), and parameters after the rest
  argument (`|a, *b, c|`) are rejected.

### Function definitions

- `function :name do |argument| … end` defines a top-level, noninteractive
  Elisp function. It accepts required, optional, and rest positional
  parameters as described above.
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
- Keyword arguments (except on `custom`, which accepts validated
  `key: expression` pairs), call-site splats (`f(*args)`), heredocs, and
  interpolation.
  `fn`, `function`, `.each`, and `command` accept the block parameters
  described above; `with_current_buffer` and `el.*` accept only
  parameterless blocks; `insert` does not accept a block.
- `redo` and `retry`; `break`/`next` placement crossing an `fn` or `let`
  block boundary; non-string `interactive` specifications; rescue conditions
  that are not literal symbols; rescue clauses binding different variable
  names; a `begin` block with neither a rescue nor an ensure clause;
  `let` with call arguments, a rest parameter, or an initializer referencing
  a later binding.
- Executable top-level expressions: a `.ruri` file may contain only
  definitions and declarations — `command`, `function`, `variable`,
  `variable_local`, `constant`, `custom`, `require`, and `provide`
  (plus comments).
- Nested `command` or `function` definitions; `interactive` outside a command body,
  duplicated, or not first; empty `with_current_buffer` blocks;
  `insert` with a block.
- Macro definitions (`macro :name do … end`). A Ruri macro body would run
  at expansion time over unevaluated forms, which requires an interpreter
  for the language itself; restricting bodies to single quasiquoted
  templates was considered and rejected because the escape semantics
  (argument binding, rest arguments, depth) would form a second language
  to specify and trust. Write the generated Elisp directly or use `fn`
  values instead.
- Non-place arguments to the typed place operators (a place must be a
  variable symbol, Ruri local, `var(:name)`, or `el.*` form); `setf` with
  multiple place/value pairs; blocks on place operators.

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

Loop escapes beyond `break` and `next` remain out of scope. A raw Lisp
escape hatch stays out of scope until its trust boundary and serialization
rules are specified in this contract first: whatever surface it gets, it
must never interpolate raw source text into emitted Lisp — every emitted
byte must still pass through the validating `Elisp` constructors and the
deterministic printer.

## Path toward broad Elisp coverage

Ruri aims to cover practical Emacs Lisp source programs, rather than duplicate
the reader syntax or bytecode format one token at a time. Generic `el.*` calls
and body forms provide the open-ended function, macro, and special-form layer.
The remaining language work is primarily about representing values and lexical
structure safely:

1. Nested quasiquotation and richer reader data; v0.6 provides evaluated
   lists and cons cells, literal quote, and single-level quasiquote with
   unquote and splicing.
2. Broader iteration, loop exits, and assignment operators; v0.7 provides
   boolean, comparison, arithmetic, `while`, `until`, and side-effecting
   `.each` syntax.
3. Variable and package structure; v0.9 provides `variable`, `constant`,
   `custom` (with arbitrary keyword pairs), `require`, and `provide`,
   documentation strings for commands and functions, and `var` reads of
   dynamic Elisp variables.
4. Parameters and interactive commands; v0.10 provides optional and rest
   parameters for functions and lambdas, command parameters, and
   interactive string specifications with entry-time parameter defaults.
5. Error handling, nonlocal exits, and value-producing iteration; v0.11
   provides `begin`/`rescue`/`else` (condition-case), `ensure`
   (unwind-protect), `catch`/`throw` with symbol tags, `break`, `next`,
   `return`, and `.map`/`.select`/`.find` lowering to mapcar and the seq
   functions.
6. Binding structure and safe Elisp surface; v0.12 provides scoped `let`
   bindings lowering to `let*` with Ruby-default initializer semantics,
   `.times` counting loops (dotimes), typed generalized places for
   `el.setf`/`el.push`/`el.pop`/`el.cl_incf`/`el.cl_decf`, compile-time
   rejection of `el.*` calls with unevaluated binding positions, and
   nested quasiquotation with Common Lisp depth semantics.

Some Elisp facilities will remain available through explicit `el.*` forms
instead of receiving dedicated Ruby syntax. That keeps Ruri small while still
allowing the generated program to use the wider Emacs API.
