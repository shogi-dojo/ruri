# Prepare Ruri for merge and implement the next language phases

**Full Path**: `/Users/mac/projects/ruri/local-notes/ruri-next-phases.md`

## Context
Ruri is a Ruby-syntax DSL that compiles structurally through Prism into dependency-free Emacs Lisp; source must never be evaluated as Ruby. Work is on `feat/ruri-hello-world-poc`, PR https://github.com/shogi-dojo/ruri/pull/1, currently mergeable into `main`. Version 0.8 already has the complete authoring loop: CLI compilation, atomic output, Emacs compile/load commands, commands, functions, required parameters, return values, recursion, lambdas, locals, conditionals, operators, loops, Lisp data, and explicit `el.*` calls. Preserve idiomatic zero-argument calls such as `el.buffer_name` without `()` and the pipeline `Prism AST → typed Ruri forms → generic Elisp AST → deterministic printer`.

## Reproduce Steps
1. `cd /Users/mac/projects/ruri`
2. `git checkout feat/ruri-hello-world-poc && git pull --ff-only`
3. Inspect PR state: `gh pr view 1 --json mergeable,mergeStateStatus,statusCheckRollup,body`
4. Run Ruby tests: `bundle exec ruby -Itest test/compiler_test.rb`
5. Run integration tests: `emacs -Q --batch -L lisp -l test/ruri-test.el -f ert-run-tests-batch-and-exit`
6. Read the exact contract at `/Users/mac/projects/ruri/docs/language.md`, especially lines 53, 155, and 258.

## Current Issue
There is no failing compiler behavior known at the merge boundary. The PR has no GitHub status checks, and its description is stale: it still claims the v0 contract, 64 Ruby tests, and 7 ERT tests; the branch is v0.8 with 123 Ruby tests and 14 ERT tests. Add CI and refresh the PR description before merging, without expanding this initial PR with another language feature.

For the next phase, the largest language gap is Emacs variable and package structure. Ruri can call most functions through `el.*`, but it has no direct syntax for reading dynamic/global Elisp variables or defining `defvar`, `defconst`, and `defcustom`, and top-level input accepts only commands and functions. It also lacks top-level `require` and `provide`. Do not treat these as ordinary evaluated `el.*` arguments: special forms have unevaluated symbol, binding, and place positions, so constructs such as `el.setq(:name, value)` would produce the wrong shape. Model them as typed Ruri forms with explicit lowering.

## Plan
1. Pre-merge: add a GitHub Actions workflow that runs the Ruby suite and ERT on a supported Ruby/Emacs environment; update PR #1 title/body and test counts.
2. Phase 1: design typed syntax for Elisp variable reads and top-level `variable`, `constant`, `custom`, `require`, and `provide`; include documentation strings and preserve the no-raw-Lisp safety boundary.
3. Phase 2: support optional/rest function and lambda parameters, command parameters, interactive specifications, and prefix arguments.
4. Phase 3: add explicit return and loop exits, then error/cleanup forms mapping to `condition-case`, `unwind-protect`, `catch`, and `throw`; expand iteration with value-producing `map`, `select`, and `find` semantics distinct from side-effecting `.each`/`mapc`.
5. Phase 4: handle binding lists, generalized places, macro definitions, and nested quasiquotation. Introduce a low-level escape hatch only after its trust boundary and serialization rules are specified; never interpolate raw source into emitted Lisp.
6. Phase 5: add a `.ruri` major mode, indentation/font locking, compile-on-save, better source mapping, optional byte compilation, gem packaging, and easier Emacs package installation.
7. Keep each phase in a focused PR and update `/Users/mac/projects/ruri/docs/language.md` with every accepted and rejected construct.

## How to Verify
1. `bundle exec ruby -Itest test/compiler_test.rb` → all Ruby tests pass.
2. `emacs -Q --batch -L lisp -l test/ruri-test.el -f ert-run-tests-batch-and-exit` → all ERT tests pass.
3. `bundle exec ruby bin/ruri compile examples/hello.ruri --output examples/hello.el` → exits 0 and produces readable v0.8+ Lisp.
4. `emacs -Q --batch -f batch-byte-compile examples/hello.el` → exits 0.
5. `emacs -Q --batch --eval "(setq load-prefer-newer t)" -L lisp -l ruri --eval "(checkdoc-file \"lisp/ruri.el\")"` → no output/errors.
6. `git diff --check` → no whitespace errors; `git status --short` contains only intended changes.
7. For every new syntax form, add parser rejection tests, lowerer shape tests, emitted Lisp tests, and at least one real-Emacs ERT behavior test.
8. Before merging PR #1, `gh pr view 1 --json mergeable,mergeStateStatus,statusCheckRollup,body` should show a clean merge, passing checks, and an accurate description.

## Relevant Files
- `/Users/mac/projects/ruri/lib/ruri/parser.rb:164` — top-level dispatch; expression parsing starts at line 575.
- `/Users/mac/projects/ruri/lib/ruri/forms.rb` — typed, validated Ruri representation.
- `/Users/mac/projects/ruri/lib/ruri/lowerer.rb:46` — definition lowering; expression lowering starts at line 184.
- `/Users/mac/projects/ruri/lib/ruri/elisp.rb` and `/Users/mac/projects/ruri/lib/ruri/printer.rb` — generic Elisp AST and safe deterministic serialization.
- `/Users/mac/projects/ruri/lib/ruri/cli.rb:64` — atomic output replacement.
- `/Users/mac/projects/ruri/lisp/ruri.el:96` — Emacs compile/load integration.
- `/Users/mac/projects/ruri/docs/language.md:258` — roadmap and exact language contract.
- `/Users/mac/projects/ruri/test/parser_test.rb`, `/Users/mac/projects/ruri/test/lowerer_test.rb`, `/Users/mac/projects/ruri/test/emitter_test.rb`, `/Users/mac/projects/ruri/test/ruri-test.el` — required coverage layers.

## Out of Scope
Do not postpone PR #1 until Ruri covers all of Emacs Lisp. Do not compile to Emacs bytecode directly, execute `.ruri` as Ruby, add Ruby objects/gems, or bypass the typed AST with string-generated Lisp.
