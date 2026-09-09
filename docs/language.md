# Ruri language contract — version 0

Ruri (瑠璃) is Ruby-shaped scripting for Emacs. A `.ruri` source file is a
Ruby-syntax DSL that compiles to an ordinary, dependency-free Emacs Lisp
file. Ruby syntax is the contract; the Ruby runtime is not. This document
is the exact scope of version 0: every construct below is supported,
everything else is rejected with a source position.

## Pipeline

```
.ruri source → Prism parse → validation → internal forms → escaped .el text
```

- The whole input is parsed and validated before anything is emitted. A
  file with one valid command and one invalid line produces no output.
- The compiler never evaluates Ruby input: no `eval`, `load`,
  `instance_eval`, or any other execution of source text. The Prism AST is
  matched structurally and internal forms are serialized by a structured
  emitter, so string literals can never become additional Lisp forms.
- Generated files begin with `;;; -*- lexical-binding: t; -*-`, identify
  the `.ruri` file they were generated from, and have no runtime
  dependency on Ruby, the compiler, or any Emacs helper package.

## Supported constructs

| Source construct | Meaning and restriction |
| --- | --- |
| `command :hello_buffer do … end` | Top-level command definition; emits `(defun hello-buffer () …)`. Exactly one literal symbol argument, no parameters, no receiver, no block parameters, no nested commands. Multiple distinct commands per file are allowed. |
| `interactive` | Emits `(interactive)`. Exactly once and first in each command body; no arguments, no block. |
| `with_current_buffer("*scratch*") do … end` | Emits `(with-current-buffer "*scratch*" …)`. Exactly one literal string argument, nonempty block, no block parameters. Valid inside a command body or nested inside another buffer block. Uses an existing buffer and preserves normal Emacs missing-buffer errors. |
| `insert("text")` | Emits `(insert "text")`. Exactly one literal string argument, no block. Valid inside a command body or a buffer block. |
| Comments and whitespace | Accepted according to Ruby syntax (`#` line comments, `=begin`/`=end` block comments); no effect on semantics. |

## Names

- Command names must match ASCII `[a-z][a-z0-9_]*` in the source.
- Each `_` becomes `-` in the emitted Emacs Lisp name (`:hello_buffer`
  defines `hello-buffer`).
- Two commands in one file must not define the same name. Because the source
  grammar excludes hyphens, underscore-to-hyphen conversion is one-to-one for
  valid command names.
- Reloading the same extension may redefine its own command normally —
  the duplicate check is per compile unit, not per Emacs session.

## Strings

- Ordinary Ruby single- and double-quoted string literals are supported
  through Prism's decoded literal value, so Ruby escape semantics
  (`\n`, `\t`, `\\`, `\"`, `\e`, `\u{...}`) work as in Ruby.
- The emitter escapes every character that is special in Emacs Lisp
  string syntax: backslash, double quote, newline, tab, carriage return,
  and other ASCII control characters (emitted as three-digit octal
  escapes). Non-ASCII UTF-8 characters are written literally and the
  output file is UTF-8.
- Rejected in v0: string interpolation (`#{…}`), heredocs, character
  literals, and concatenated or adjacent string forms.

## Rejected outright

Everything outside the table above, including but not limited to:

- Ruby variables, assignments, classes, modules, conditionals, loops,
  arrays, hashes, ranges, booleans/`nil` literals, numbers as statements.
- Explicit receivers (`Kernel.insert("x")`, `foo.bar`), safe-navigation,
  operator calls, arbitrary method calls, `require`, `lambda`/`proc`.
- Block or keyword arguments on any supported construct, splats,
  default parameters, heredocs, interpolation.
- Executable top-level expressions: a `.ruri` file may contain only
  command definitions (plus comments).
- Nested `command` definitions; `interactive` outside a command body,
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

Generic function calls, local variables, closures, additional macros,
and a broader expression language are explicitly out of scope until the
hello-world vertical slice works end to end.
