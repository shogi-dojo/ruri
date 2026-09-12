;;; ruri-test.el --- End-to-end tests for ruri -*- lexical-binding: t; -*-

(require 'ert)
(require 'ruri)

(defconst ruri-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Project root, derived from this file's location.")

;; Development compiler configuration: bundle exec ruby with absolute
;; paths and the correct Gemfile environment (see lisp/ruri.el commentary).
(setq ruri-compiler-executable "bundle"
      ruri-compiler-arguments
      (list "exec" "ruby" (expand-file-name "bin/ruri" ruri-test--root) "compile")
      ruri-compiler-environment
      (list (concat "BUNDLE_GEMFILE=" (expand-file-name "Gemfile" ruri-test--root))))

(defconst ruri-test--greeting "Hello from Ruby syntax!\n")

(defun ruri-test--clear-scratch ()
  (with-current-buffer "*scratch*" (erase-buffer)))

(defun ruri-test--scratch-string ()
  (with-current-buffer "*scratch*" (buffer-string)))

(ert-deftest ruri-test/load-example-defines-and-runs-command ()
  (ruri-load-file (expand-file-name "examples/hello.ruri" ruri-test--root))
  (should (commandp 'hello-buffer))
  (ruri-test--clear-scratch)
  (call-interactively #'hello-buffer)
  (should (equal ruri-test--greeting (ruri-test--scratch-string))))

(ert-deftest ruri-test/invocation-restores-current-buffer-and-window ()
  (ruri-load-file (expand-file-name "examples/hello.ruri" ruri-test--root))
  (ruri-test--clear-scratch)
  (let ((window (selected-window)))
    (with-temp-buffer
      (let ((temp (current-buffer)))
        (call-interactively #'hello-buffer)
        (should (eq (current-buffer) temp))))
    (should (eq (selected-window) window)))
  (should (equal ruri-test--greeting (ruri-test--scratch-string))))

(ert-deftest ruri-test/inserts-at-point-appending-on-repeated-invocation ()
  (ruri-load-file (expand-file-name "examples/hello.ruri" ruri-test--root))
  (ruri-test--clear-scratch)
  (with-current-buffer "*scratch*" (goto-char (point-min)))
  (call-interactively #'hello-buffer)
  (call-interactively #'hello-buffer)
  (should (equal (concat ruri-test--greeting ruri-test--greeting)
                 (ruri-test--scratch-string))))

(ert-deftest ruri-test/compile-file-returns-output-beside-source ()
  (let* ((source (expand-file-name "examples/hello.ruri" ruri-test--root))
         (output (ruri-compile-file source))
         (text (with-temp-buffer
                 (insert-file-contents output)
                 (buffer-string))))
    (should (file-exists-p output))
    (should (equal "hello.el" (file-name-nondirectory output)))
    ;; Exact whole-file equality is covered by the Ruby compiler tests;
    ;; here we pin the structural parts that matter for loading.
    (should (string-prefix-p ";;; -*- lexical-binding: t; -*-\n" text))
    (should (string-suffix-p
             "(defun hello-buffer ()\n  (interactive)\n  (with-current-buffer \"*scratch*\"\n    (insert \"Hello from Ruby syntax!\\n\")))\n"
             text))))

(ert-deftest ruri-test/handles-paths-with-spaces ()
  (let* ((dir (make-temp-file "ruri space dir " t))
         (source (expand-file-name "spaced.ruri" dir)))
    (with-temp-file source
      (insert "command :space_cmd do\n"
              "  interactive\n"
              "  insert(\"SPACED OK\\n\")\n"
              "end\n"))
    (ruri-load-file source)
    (should (commandp 'space-cmd))
    (let ((buf (generate-new-buffer " *ruri spaced*")))
      (unwind-protect
          (progn
            (set-buffer buf)
            (call-interactively #'space-cmd)
            (should (equal "SPACED OK\n" (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest ruri-test/failed-compilation-never-loads-stale-output ()
  (let* ((dir (make-temp-file "ruri stale " t))
         (source (expand-file-name "stale.ruri" dir))
         (output (expand-file-name "stale.el" dir)))
    ;; First, a valid definition compiles and loads.
    (with-temp-file source
      (insert "command :stale_cmd do\n"
              "  interactive\n"
              "  insert(\"GOOD v1\\n\")\n"
              "end\n"))
    (ruri-load-file source)
    (should (commandp 'stale-cmd))
    (let ((good-output (with-temp-buffer
                         (insert-file-contents output)
                         (buffer-string))))
      ;; Then the same file becomes invalid; loading must fail and must
      ;; not redefine the command from (or even touch) the old output.
      (with-temp-file source
        (insert "command :a do\n  interactive\n  insert(1)\nend\n"))
      (should-error (ruri-load-file source))
      (should (equal good-output
                     (with-temp-buffer
                       (insert-file-contents output)
                       (buffer-string)))))))

(ert-deftest ruri-test/generated-elc-runs-in-fresh-batch-emacs ()
  (let* ((source (expand-file-name "examples/hello.ruri" ruri-test--root)))
    (let ((output (ruri-compile-file source)))
      (let ((elc (concat (file-name-sans-extension output) ".elc")))
        (byte-compile-file output)
        (let ((child-code (concat
                           "(progn (with-current-buffer \"*scratch*\" (erase-buffer))"
                           " (call-interactively #'hello-buffer)"
                           " (princ (concat \"RURI-ELC:\""
                           " (with-current-buffer \"*scratch*\" (buffer-string)))))")))
          (unwind-protect
              (progn
                (with-temp-buffer
                  (should (zerop (call-process "emacs" nil t nil
                                               "-Q" "--batch"
                                               "-l" elc
                                               "--eval" child-code)))
                  (should (string-suffix-p
                           (concat "RURI-ELC:" ruri-test--greeting)
                           (buffer-string)))))
            (delete-file elc)))))))

(ert-deftest ruri-test/generic-calls-and-literals-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri expressions " t))
         (source (expand-file-name "expressions.ruri" dir)))
    (with-temp-file source
      (insert "command :expression_cmd do\n"
              "  interactive\n"
              "  el.insert(el.format(\"%s/%s/%s %S\", true, false, nil, "
              "[1, 2.5, :hello_world]))\n"
              "end\n"))
    (ruri-load-file source)
    (with-temp-buffer
      (call-interactively #'expression-cmd)
      (should (equal "t/nil/nil [1 2.5 hello-world]" (buffer-string))))))

(ert-deftest ruri-test/locals-conditionals-and-elsif-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri locals " t))
         (source (expand-file-name "locals.ruri" dir)))
    (with-temp-file source
      (insert "command :local_cmd do\n"
              "  interactive\n"
              "  case_fold_search = \"unset\"\n"
              "  if false\n"
              "    case_fold_search = \"wrong\"\n"
              "  elsif true\n"
              "    case_fold_search = \"right\"\n"
              "  else\n"
              "    case_fold_search = \"also wrong\"\n"
              "  end\n"
              "  unless false\n"
              "    el.insert(case_fold_search)\n"
              "  end\n"
              "end\n"))
    (ruri-load-file source)
    (let ((case-fold-search 'untouched))
      (with-temp-buffer
        (call-interactively #'local-cmd)
        (should (equal "right" (buffer-string))))
      (should (eq case-fold-search 'untouched)))))

(ert-deftest ruri-test/generic-block-forms-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri block forms " t))
         (source (expand-file-name "blocks.ruri" dir)))
    (with-temp-file source
      (insert "command :block_cmd do\n"
              "  interactive\n"
              "  el.save_excursion do\n"
              "    el.goto_char(el.point_min)\n"
              "    el.insert(\"start-\")\n"
              "  end\n"
              "  el.insert(\"-end\")\n"
              "end\n"))
    (ruri-load-file source)
    (with-temp-buffer
      (insert "body")
      (call-interactively #'block-cmd)
      (should (equal "start-body-end" (buffer-string))))))

(ert-deftest ruri-test/lambdas-captures-and-function-references-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri callbacks " t))
         (source (expand-file-name "callbacks.ruri" dir)))
    (with-temp-file source
      (insert "command :callback_cmd do\n"
              "  interactive\n"
              "  prefix = \"<\"\n"
              "  formatter = fn do |value|\n"
              "    el.concat(prefix, value, \">\")\n"
              "  end\n"
              "  el.insert(el.mapconcat(formatter, [\"a\", \"b\"], \",\"))\n"
              "  el.insert(el.funcall(function(:identity), \"!\"))\n"
              "end\n"))
    (ruri-load-file source)
    (with-temp-buffer
      (call-interactively #'callback-cmd)
      (should (equal "<a>,<b>!" (buffer-string))))))

(ert-deftest ruri-test/lisp-data-and-quasiquote-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri data " t))
         (source (expand-file-name "data.ruri" dir)))
    (with-temp-file source
      (insert "command :data_cmd do\n"
              "  interactive\n"
              "  tail = list(\"b\", \"c\")\n"
              "  pair = quote(cons(:key, :value))\n"
              "  template = quasiquote(list(:head, "
              "unquote(el.upcase(\"x\")), splice(tail)))\n"
              "  el.insert(el.format(\"%S|%S\", pair, template))\n"
              "end\n"))
    (ruri-load-file source)
    (with-temp-buffer
      (call-interactively #'data-cmd)
      (should (equal "(key . value)|(head \"X\" \"b\" \"c\")"
                     (buffer-string))))))

(ert-deftest ruri-test/operators-and-loops-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri loops " t))
         (source (expand-file-name "loops.ruri" dir)))
    (with-temp-file source
      (insert "command :loop_cmd do\n"
              "  interactive\n"
              "  count = 0\n"
              "  total = 0\n"
              "  while count < 3 && !(count == 9)\n"
              "    total = total + count\n"
              "    count = count + 1\n"
              "  end\n"
              "  until count >= 5\n"
              "    count = count + 1\n"
              "  end\n"
              "  list(1, 2, 3).each do |item|\n"
              "    total = total + item\n"
              "  end\n"
              "  safe_and = false && el.error(\"must short-circuit\")\n"
              "  safe_or = true || el.error(\"must short-circuit\")\n"
              "  power = 2 ** 3\n"
              "  math = (power * 3 - 4) / 2 % 5\n"
              "  signed = -power + +count\n"
              "  ordered = 2 <= 2 && 3 > 2\n"
              "  el.insert(el.format(\"%d/%d/%S/%d/%d/%S\", count, total, "
              "count != total && !false, math, signed, ordered))\n"
              "end\n"))
    (ruri-load-file source)
    (with-temp-buffer
      (call-interactively #'loop-cmd)
      (should (equal "5/9/t/0/-3/t" (buffer-string))))))

(ert-deftest ruri-test/top-level-functions-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri functions " t))
         (source (expand-file-name "functions.ruri" dir)))
    (with-temp-file source
      (insert "function :factorial do |number|\n"
              "  if number <= 1\n"
              "    1\n"
              "  else\n"
              "    number * el.factorial(number - 1)\n"
              "  end\n"
              "end\n\n"
              "function :decorate do |value|\n"
              "  prefix = \"<\"\n"
              "  el.concat(prefix, value, \">\")\n"
              "end\n\n"
              "command :function_cmd do\n"
              "  interactive\n"
              "  el.insert(el.format(\"%d/%s/%d\", el.factorial(5), "
              "el.decorate(\"x\"), el.funcall(function(:factorial), 4)))\n"
              "end\n"))
    (ruri-load-file source)
    (should (functionp #'factorial))
    (should (functionp #'decorate))
    (should (= 120 (factorial 5)))
    (should (equal "<x>" (decorate "x")))
    (with-temp-buffer
      (call-interactively #'function-cmd)
      (should (equal "120/<x>/24" (buffer-string))))))

(ert-deftest ruri-test/package-forms-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri package " t))
         (source (expand-file-name "package.ruri" dir)))
    (with-temp-file source
      (insert "require :subr_x\n"
              "\n"
              "variable :ruri_test_counter, 7, \"Counter for tests.\"\n"
              "\n"
              "custom :ruri_test_style, :plain, \"Style setting.\", type: :symbol\n"
              "\n"
              "command :ruri_test_greet_cmd do\n"
              "  doc \"Greet using the test counter.\"\n"
              "  interactive\n"
              "  el.insert(el.format(\"count=%d style=%S folded=%S\",\n"
              "                      var(:ruri_test_counter),\n"
              "                      var(:ruri_test_style),\n"
              "                      var(:case_fold_search)))\n"
              "end\n"
              "\n"
              "function :ruri_test_double do |n|\n"
              "  doc \"Double N.\"\n"
              "  n * 2\n"
              "end\n"
              "\n"
              "provide :ruri_test_pack\n"))
    (ruri-load-file source)
    (should (featurep (quote ruri-test-pack)))
    (should (= 7 (default-value (quote ruri-test-counter))))
    (should (eq (quote plain) (default-value (quote ruri-test-style))))
    (should (eq (quote symbol) (get (quote ruri-test-style) (quote custom-type))))
    (should (commandp (quote ruri-test-greet-cmd)))
    (with-temp-buffer
      (call-interactively (quote ruri-test-greet-cmd))
      (should (string-prefix-p "count=7 style=plain" (buffer-string))))
    (should (= 84 (ruri-test-double 42)))
    (should (equal "Greet using the test counter."
                   (documentation (quote ruri-test-greet-cmd))))
    (should (equal "Double N." (documentation (quote ruri-test-double))))))

(ert-deftest ruri-test/optional-and-rest-parameters-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri params " t))
         (source (expand-file-name "params.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_greet do |name, punctuation = \"!\"|\n"
              "  doc \"Greet NAME with PUNCTUATION.\"\n"
              "  el.concat(name, punctuation)\n"
              "end\n\n"
              "function :ruri_test_fallback do |value, fallback = \"d\"|\n"
              "  doc \"Return VALUE, or FALLBACK when VALUE is nil.\"\n"
              "  if value\n"
              "    value\n"
              "  else\n"
              "    fallback\n"
              "  end\n"
              "end\n\n"
              "function :ruri_test_count do |first, *more|\n"
              "  doc \"Describe FIRST and the rest.\"\n"
              "  el.concat(first, el.format(\"/%d\", el.length(more)))\n"
              "end\n"))
    (ruri-load-file source)
    (should (equal "hi!" (ruri-test-greet "hi")))
    (should (equal "hi?" (ruri-test-greet "hi" "?")))
    ;; An entry-time default re-applies when nil is passed explicitly;
    ;; this documents the plain-defun nil-collision semantics.
    (should (equal "d" (ruri-test-fallback nil)))
    (should (equal "v" (ruri-test-fallback "v")))
    (should (equal "a/2" (ruri-test-count "a" "b" "c")))
    (should (equal "a/0" (ruri-test-count "a")))))

(ert-deftest ruri-test/command-parameters-and-interactive-specs-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri commands " t))
         (source (expand-file-name "commands.ruri" dir)))
    (with-temp-file source
      (insert "command :ruri_test_echo_cmd do |count, punctuation = \"!\"|\n"
              "  doc \"Insert COUNT and PUNCTUATION.\"\n"
              "  interactive \"p\"\n"
              "  el.insert(el.format(\"%d%s\", count, punctuation))\n"
              "end\n\n"
              "command :ruri_test_prefix_cmd do |raw_prefix|\n"
              "  doc \"Insert the raw prefix argument.\"\n"
              "  interactive \"P\"\n"
              "  el.insert(el.format(\"%S\", raw_prefix))\n"
              "end\n"))
    (ruri-load-file source)
    ;; The interactive string spec feeds the command parameter; the
    ;; optional punctuation default applies for the missing second arg.
    (with-temp-buffer
      (let ((current-prefix-arg nil))
        (call-interactively #'ruri-test-echo-cmd))
      (should (equal "1!" (buffer-string))))
    (with-temp-buffer
      (let ((current-prefix-arg 7))
        (call-interactively #'ruri-test-echo-cmd))
      (should (equal "7!" (buffer-string))))
    ;; "P" passes the raw prefix argument through to the parameter.
    (with-temp-buffer
      (let ((current-prefix-arg '(4)))
        (call-interactively #'ruri-test-prefix-cmd))
      (should (equal "(4)" (buffer-string))))
    (with-temp-buffer
      (let ((current-prefix-arg nil))
        (call-interactively #'ruri-test-prefix-cmd))
      (should (equal "nil" (buffer-string))))))

(ert-deftest ruri-test/error-handling-runs-in-emacs ()
  (let* ((dir (make-temp-file "ruri rescue " t))
         (source (expand-file-name "rescue.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_safe_div do |a, b|\n"
              "  doc \"Divide A by B with error reporting.\"\n"
              "  begin\n"
              "    el.format(\"%S\", a / b)\n"
              "  rescue :arith_error, :range_error => problem\n"
              "    el.concat(\"math:\", el.error_message_string(problem))\n"
              "  rescue\n"
              "    \"other\"\n"
              "  else\n"
              "    el.concat(\"ok:\")\n"
              "  end\n"
              "end\n"))
    (ruri-load-file source)
    ;; Success path: the else handler supplies the result.
    (should (string-prefix-p "ok:" (ruri-test-safe-div 6 3)))
    ;; A signalled arith-error is caught and the error object is bound.
    (should (string-prefix-p "math:Arithmetic" (ruri-test-safe-div 1 0)))
    ;; Any other error falls through to the bare rescue clause.
    (should (equal "other" (ruri-test-safe-div "a" "b")))))

(ert-deftest ruri-test/unwind-protect-runs-cleanup-on-error-path ()
  (let* ((dir (make-temp-file "ruri ensure " t))
         (source (expand-file-name "ensure.ruri" dir)))
    (with-temp-file source
      (insert "variable :ruri_test_cleanups, 0, \"Cleanup counter.\"\n\n"
              "function :ruri_test_guarded do\n"
              "  doc \"Returns 42 while always running cleanup.\"\n"
              "  begin\n"
              "    42\n"
              "  ensure\n"
              "    assign :ruri_test_cleanups, var(:ruri_test_cleanups) + 1\n"
              "  end\n"
              "end\n\n"
              "function :ruri_test_rescued do |a, b|\n"
              "  doc \"Catches a math error and still runs cleanup.\"\n"
              "  begin\n"
              "    el.format(\"%S\", a / b)\n"
              "  rescue :arith_error\n"
              "    \"math\"\n"
              "  ensure\n"
              "    assign :ruri_test_cleanups, var(:ruri_test_cleanups) + 1\n"
              "  end\n"
              "end\n"))
    (ruri-load-file source)
    ;; The body value survives the cleanup, which runs exactly once.
    (should (= 42 (ruri-test-guarded)))
    (should (= 1 ruri-test-cleanups))
    ;; The handler supplies the value on the error path, and the cleanup
    ;; still runs after the handler.
    (should (equal "math" (ruri-test-rescued 1 0)))
    (should (= 2 ruri-test-cleanups))))

(ert-deftest ruri-test/catch-and-throw-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri catch " t))
         (source (expand-file-name "catch.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_seek do |limit|\n"
              "  doc \"First item whose double reaches LIMIT, or none.\"\n"
              "  catch(:found) do\n"
              "    list(1, 2, 3, 4).each do |item|\n"
              "      if item * 2 >= limit\n"
              "        throw :found, item\n"
              "      end\n"
              "    end\n"
              "    :none\n"
              "  end\n"
              "end\n"))
    (ruri-load-file source)
    ;; The thrown value crosses the tag and becomes the catch value.
    (should (= 2 (ruri-test-seek 4)))
    (should (eq 'none (ruri-test-seek 100)))))

(ert-deftest ruri-test/break-next-and-return-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri exits " t))
         (source (expand-file-name "exits.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_first_match do |threshold|\n"
              "  doc \"Return the first item over THRESHOLD, or -1.\"\n"
              "  list(3, 7, 11, 2).each do |item|\n"
              "    if item > threshold\n"
              "      return item\n"
              "    end\n"
              "  end\n"
              "  -1\n"
              "end\n\n"
              "function :ruri_test_sum_until_cap do |cap|\n"
              "  doc \"Sum 1, 2, 3, ... until the sum would pass CAP.\"\n"
              "  total = 0\n"
              "  count = 0\n"
              "  while true\n"
              "    count = count + 1\n"
              "    break if total + count > cap\n"
              "    total = total + count\n"
              "  end\n"
              "  total\n"
              "end\n\n"
              "function :ruri_test_skip_zeros do\n"
              "  doc \"Total nonzero items.\"\n"
              "  total = 0\n"
              "  list(2, 0, 3, 0, 4).each do |item|\n"
              "    next if item == 0\n"
              "    total = total + item\n"
              "  end\n"
              "  total\n"
              "end\n"))
    (ruri-load-file source)
    ;; return leaves the defun from inside an .each lambda.
    (should (= 7 (ruri-test-first-match 6)))
    (should (= -1 (ruri-test-first-match 99)))
    ;; break ends the while loop before the cap is exceeded.
    (should (= 10 (ruri-test-sum-until-cap 10)))
    (should (= 6 (ruri-test-sum-until-cap 9)))
    ;; next skips the zero items.
    (should (= 9 (ruri-test-skip-zeros)))))

(ert-deftest ruri-test/map-select-find-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri iteration " t))
         (source (expand-file-name "iteration.ruri" dir)))
    (with-temp-file source
      (insert "require :seq\n\n"
              "function :ruri_test_stats do |items|\n"
              "  doc \"Doubled evens and the first item over 3.\"\n"
              "  evens = items.select do |item|\n"
              "    item % 2 == 0\n"
              "  end\n"
              "  doubled = evens.map do |item|\n"
              "    item * 2\n"
              "  end\n"
              "  first_big = items.find do |item|\n"
              "    item > 3\n"
              "  end\n"
              "  list(doubled, first_big)\n"
              "end\n"))
    (ruri-load-file source)
    ;; select/map/find chain over a real list, requiring seq explicitly.
    (should (equal '((4 8 16) 4) (ruri-test-stats (list 1 2 3 4 8))))
    ;; An empty selection is Elisp nil, and find misses too.
    (should (equal '(nil nil) (ruri-test-stats (list 1))))))

(ert-deftest ruri-test/let-bindings-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri let " t))
         (source (expand-file-name "let-bindings.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_let_values do\n"
              "  doc \"Sequential bindings and the nil idiom.\"\n"
              "  base = 10\n"
              "  let do |c, a = base, b = a|\n"
              "    list(a, b, c)\n"
              "  end\n"
              "end\n"
              "\n"
              "function :ruri_test_let_shadowing do\n"
              "  doc \"The let binding shadows and restores the outer local.\"\n"
              "  x = \"outer\"\n"
              "  captured = let do |x = \"inner\"|\n"
              "    x\n"
              "  end\n"
              "  list(captured, x)\n"
              "end\n"
              "\n"
              "function :ruri_test_let_keeps_builtins_reachable do\n"
              "  doc \"A binding named message must not shadow the Elisp function.\"\n"
              "  list(el.message(\"ok\"), let do |message = 5| message end)\n"
              "end\n"
              "\n"
              "function :ruri_test_return_from_let do\n"
              "  doc \"Return targets the definition across the let.\"\n"
              "  let do |x = 1|\n"
              "    return :done\n"
              "  end\n"
              "  :unreached\n"
              "end\n"))
    (ruri-load-file source)
    ;; Sequential defaults: a reads base, b reads the new a, c binds nil.
    (should (equal '(10 10 nil) (ruri-test-let-values)))
    ;; The let binding shadows the outer local and is restored after.
    (should (equal '("inner" "outer") (ruri-test-let-shadowing)))
    ;; A binding named message must not shadow the Elisp function.
    (should (equal '("ok" 5) (ruri-test-let-keeps-builtins-reachable)))
    ;; return targets the enclosing definition from inside the let.
    (should (eq 'done (ruri-test-return-from-let)))))

(ert-deftest ruri-test/times-loops-run-in-emacs ()
  (let* ((dir (make-temp-file "ruri times " t))
         (source (expand-file-name "times.ruri" dir)))
    (with-temp-file source
      (insert "function :ruri_test_times_sums do\n"
              "  doc \"Counting loop with next and break.\"\n"
              "  total = 0\n"
              "  5.times do |i|\n"
              "    next if i == 2\n"
              "    total = total + i\n"
              "  end\n"
              "  9.times do |i|\n"
              "    break if i == 1\n"
              "    total = total + 10\n"
              "  end\n"
              "  total\n"
              "end\n"
              "\n"
              "function :ruri_test_times_value do\n"
              "  doc \"dotimes yields nil, unlike Ruby's Integer#times.\"\n"
              "  3.times do |i|\n"
              "    el.identity(i)\n"
              "  end\n"
              "end\n"))
    (ruri-load-file source)
    ;; next skips i == 2, so 0 + 1 + 3 + 4; break fires on the second
    ;; pass, adding 10 exactly once.
    (should (= 18 (ruri-test-times-sums)))
    ;; The loop form itself contributes no value.
    (should (null (ruri-test-times-value)))))

(ert-deftest ruri-test/org-fragtog-conversion-runs-in-emacs ()
  (let* ((dir (make-temp-file "ruri org-fragtog " t))
         (source (expand-file-name "org-fragtog.ruri" dir)))
    (copy-file (expand-file-name "examples/org-fragtog.ruri" ruri-test--root) source t)
    (ruri-load-file source)
    (should (featurep (quote org-fragtog)))
    (should (fboundp (quote org-fragtog-mode)))
    (should (fboundp (quote org-fragtog--post-cmd)))
    (should (= 0.0 org-fragtog-preview-delay))
    (should (equal (quote hook) (get (quote org-fragtog-ignore-predicates) (quote custom-type))))
    (with-temp-buffer
      (delay-mode-hooks (org-mode))
      (org-fragtog-mode)
      (should org-fragtog-mode)
      (should (memq (quote org-fragtog--post-cmd) post-command-hook))
      ;; With no fragments around, the hook function must run without error.
      (org-fragtog--post-cmd)
      ;; The renewed-disable path takes the &optional RENEW argument, and
      ;; the plain path relies on its nil default.
      (org-fragtog--disable-frag nil t)
      (org-fragtog--disable-frag nil)
      (should (null org-fragtog--timer))
      (org-fragtog-mode)
      (should (null org-fragtog-mode))
      (should (not (memq (quote org-fragtog--post-cmd) post-command-hook))))))

(provide (quote ruri-test))
;;; ruri-test.el ends here
