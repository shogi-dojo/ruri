# Ruri: Ruby-syntax Emacs extensions — hello-world POC

**Full Path**: `/Users/mac/projects/ruri/ruby-elisp-poc-handoff.md`

## Context
The user wants to write Emacs extensions using Ruby syntax, with the approachable DSL feel of Gemfiles and Rakefiles. Build a small, explicitly specified language that compiles to ordinary Emacs Lisp, together with a thin Emacs package for compiling and loading its source. Ruby syntax is the priority; Ruby runtime compatibility, objects, and gems are not required. This is a greenfield handoff: no implementation, repository, branch, or installed toolchain has been verified. The requested end result is a working hello-world extension, tests, and a written language contract—not only a proposal.

## Reproduce Steps
There is no existing bug to reproduce. Establish the baseline and implement this target:
1. Inspect the assigned workspace and its instructions; use a dedicated project directory if none exists. Do not assume this document's directory is the implementation repository.
2. Run `ruby --version`, `bundle --version`, and `emacs --version`; record the versions and any missing dependencies. Choose and document a supported Ruby/Prism combination and an Emacs version with lexical binding.
3. Create `examples/hello.ruri` containing exactly:

```ruby
command :hello_buffer do
  interactive
  with_current_buffer("*scratch*") do
    insert("Hello from Ruby syntax!\n")
  end
end
```

4. Implement the commands in How to Verify, then demonstrate that this source defines the Emacs command `hello-buffer`.

## Current Issue
Nothing has been built yet. The architectural question is how Emacs should consume Ruby-shaped extension files. Resolve it with an external Ruby compiler using Prism, which parses source without executing it and emits `.el`; the Emacs package invokes that compiler and loads its output. Emacs itself does not need a Ruby parser or embedded interpreter. Distributed generated `.el` files run without Ruby; compiling `.ruri` source requires Ruby and the compiler dependencies. These are proposed implementation decisions, not verified existing capabilities of a project.

## Plan
### Architecture and deliverables
The user selected **Ruri** (瑠璃), Japanese for **lapis lazuli**, as the project and language name. Its gemstone meaning and sound connect it to Ruby. Tagline: **Ruby-shaped scripting for Emacs.** Use `ruri` for the CLI and Emacs package, `.ruri` for source files, and `ruri-` for Emacs package symbols. This replaces the earlier provisional name. Name meaning: https://en.wiktionary.org/wiki/瑠璃
- Pipeline: `.ruri` → Prism AST → validated internal forms → escaped, readable `.el` → optional Emacs byte compilation to `.elc`.
- Parse the complete input, validate every node, then emit. Never use Ruby `eval`, `load`, or `instance_eval` to implement the source language. Gemfile-like ergonomics do not require Gemfile-like execution.
- Provide a Ruby CLI, dependency declaration/lockfile, small Emacs package, example, language contract, README, compiler tests, and ERT integration tests.
- Do not write a parser or direct bytecode backend. Build Lisp forms structurally and serialize them; do not splice unvalidated source strings into generated Lisp.
- Generated code must begin with `;;; -*- lexical-binding: t; -*-`, identify its source, and contain no runtime dependency on the compiler or Emacs helper package.

### Version 0 language contract
Write `docs/language.md` before or alongside implementation. The table below is the required scope; reject everything outside it explicitly.

| Source construct | Meaning and restriction |
| --- | --- |
| `command :hello_buffer do … end` | Top-level command definition; emits `(defun hello-buffer () …)`. Exactly one literal symbol argument, no parameters, no receiver, no block parameters, no nested commands. Multiple distinct commands per file are allowed. |
| `interactive` | Emits `(interactive)`. Exactly once and first in each command body for this POC; no arguments or block. |
| `with_current_buffer("*scratch*") do … end` | Emits `(with-current-buffer "*scratch*" …)`. Exactly one literal string argument, nonempty block, no block parameters. Valid inside command or nested buffer blocks. Uses an existing buffer and preserves normal Emacs missing-buffer errors. |
| `insert("text")` | Emits `(insert "text")`. Exactly one literal string argument, no block, valid inside a command or buffer block. |
| Comments and whitespace | Accepted according to Ruby syntax; do not affect semantics. |
| Names | Command names must match ASCII `[a-z][a-z0-9_]*`; replace `_` with `-`. Reject duplicate resulting definitions within a file. Reloading the same extension may redefine its command normally. |
| Strings | Support ordinary UTF-8 string literals and Ruby single/double-quote escape semantics through Prism's decoded literal value. Correctly escape Lisp quotes, backslashes, newlines, and control characters. Reject interpolation and additional string forms such as heredocs in v0. |

This is intentionally a Ruby-syntax DSL with Emacs semantics. There are no Ruby variables, classes, conditionals, loops, arrays, hashes, booleans, arbitrary method calls, shell execution, `require`, splats, keyword arguments, or general-purpose blocks in v0. Treat DSL constructs as reserved syntax rather than Ruby methods. Reject explicit receivers such as `Kernel.insert(...)`, unsupported AST shapes, and executable top-level expressions. Generic function calls, locals, closures, and additional macros can be designed after the POC passes.

Expected output, apart from harmless generated comments and formatting:

```elisp
;;; -*- lexical-binding: t; -*-
(defun hello-buffer ()
  (interactive)
  (with-current-buffer "*scratch*"
    (insert "Hello from Ruby syntax!\n")))
```

### CLI contract
From the project root, support `bundle exec ruby bin/ruri compile INPUT --output OUTPUT`. Success exits 0 and writes a UTF-8 `.el` file; failure exits nonzero and prints `path:line:column: message` to stderr, with 1-based source positions. Include the unsupported construct or syntax error in diagnostics. Validate the entire input before replacing output; use a temporary file and atomic replacement so an error preserves any existing output. Keep generated output deterministic for the same input/path. A structured emitter must prevent literal text from becoming additional Lisp forms.

### Emacs package contract
Implement `lisp/ruri.el` with `(provide 'ruri)`, customizable compiler executable and argument list, and interactive `ruri-compile-file` and `ruri-load-file` commands that prompt for a `.ruri` file. Default the compiler invocation to a documented installed `ruri` executable; document the development configuration using `bundle exec ruby` with absolute project paths and the correct Gemfile environment. Invoke the compiler with separate process arguments, never a concatenated shell command. A synchronous subprocess is sufficient for this small POC.

`ruri-compile-file` compiles beside the source as `NAME.el` and returns the output path. `ruri-load-file` compiles successfully before loading that exact `.el` path, avoiding any stale `.elc`. On failure, surface compiler diagnostics and never load an older output. Handle paths containing spaces. Provide clear missing-executable errors. No file watcher, automatic evaluation on opening files, or custom major mode is required. Optional `.elc` generation uses Emacs's existing byte compiler, separately from parsing.

## How to Verify
The following are required interfaces to create, not commands already executed. Run them from the implementation project root and report actual results:

```sh
bundle install
bundle exec ruby -Itest test/compiler_test.rb
bundle exec ruby bin/ruri compile examples/hello.ruri --output examples/hello.el
emacs -Q --batch -L lisp -l test/ruri-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -f batch-byte-compile examples/hello.el
```

Compiler tests must cover exact output semantics, Unicode and escaping round trips, syntax errors, unsupported constructs with source positions, duplicate commands, and preserving previous output after a failure. Include a negative fixture containing `system("touch ...")`; assert rejection and no side effect. Inspect the implementation to confirm it never evaluates Ruby input; a negative test alone does not establish that property.

ERT must invoke the real compiler, load its output, assert `(commandp 'hello-buffer)`, clear `*scratch*`, invoke `(call-interactively #'hello-buffer)`, and assert the exact buffer string `"Hello from Ruby syntax!\n"`. Verify current-buffer restoration by invoking from another buffer. Also test `ruri-load-file`, paths with spaces, and failed compilation without loading stale output. In a fresh batch Emacs, load the generated `.elc` and repeat the hello-world behavior test. Ruby subprocess success alone is insufficient.

Manual acceptance: load `lisp/ruri.el`, configure the compiler as documented, run `M-x ruri-load-file` on `examples/hello.ruri`, run `M-x hello-buffer`, and switch to `*scratch*` to see the greeting. The command inserts at the buffer's current point and does not switch the selected window; repeated invocation appends/inserts another greeting according to the point. Document this expected behavior. If a required tool cannot be installed or executed, report the exact blocker and mark its checks unverified.

## Relevant Files
Only this handoff exists as a deliverable of the planning conversation. The following are proposed paths relative to the implementation project root:
- `Gemfile`, `Gemfile.lock`, `bin/ruri`, `lib/ruri/`: dependencies, CLI, validation, internal forms, Lisp serialization.
- `lisp/ruri.el`: compile/load Emacs integration.
- `examples/hello.ruri`, generated `examples/hello.el`: executable acceptance example.
- `test/compiler_test.rb`, `test/ruri-test.el`: compiler and end-to-end behavior tests.
- `docs/language.md`, `README.md`: exact v0 contract, supported versions, installation and copyable demo commands.

## Out of Scope
Full Ruby compatibility, gems running inside Emacs, an embedded Ruby VM, RPC plugin hosting, direct bytecode emission, native compilation integration, arbitrary Lisp escape hatches, editor source maps, publishing a package, and broadening the language before hello-world works. Do not delegate only a language proposal back to the user: deliver the implemented vertical slice and its documented limits.

## Notes
- Prism parser and Ruby support: https://ruby.github.io/prism/
- Emacs byte compilation API: https://www.gnu.org/software/emacs/manual/html_node/elisp/Compilation-Functions.html
- Emacs lexical/dynamic scoping: https://www.gnu.org/software/emacs/manual/html_node/elisp/Variable-Scoping.html
- Finish with the project location, exact successful demo commands, generated Lisp example, test results, and any remaining limitations. Distinguish executed checks from proposed commands.
