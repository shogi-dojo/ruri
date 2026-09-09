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

(provide 'ruri-test)
;;; ruri-test.el ends here
