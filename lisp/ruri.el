;;; ruri.el --- Compile and load Ruri (Ruby-shaped) extensions -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: extensions, languages
;; URL: https://github.com/shogi-dojo/ruri

;;; Commentary:

;; Ruri (瑠璃) is Ruby-shaped scripting for Emacs: `.ruri' source files
;; are written with Ruby syntax and compiled to ordinary, dependency-free
;; Emacs Lisp by an external compiler.  See docs/language.md for the
;; exact language contract.

;; `ruri-compile-file' compiles a `.ruri' file to `NAME.el' beside the
;; source.  `ruri-load-file' compiles first and only then loads the
;; freshly generated `.el', so a failed compilation never loads stale
;; output.  The compiler runs as a synchronous subprocess with separate
;; arguments (never a concatenated shell command), so paths containing
;; spaces are safe.

;; The default configuration expects the `ruri' executable on your
;; `exec-path'.  To run the compiler from a development checkout
;; instead, use absolute paths and the correct Gemfile environment:
;;
;;   (with-eval-after-load 'ruri
;;     (setq ruri-compiler-executable "bundle"
;;           ruri-compiler-arguments
;;           '("exec" "ruby" "/absolute/path/to/ruri/bin/ruri" "compile")
;;           ruri-compiler-environment
;;           '("BUNDLE_GEMFILE=/absolute/path/to/ruri/Gemfile")))

;;; Code:

(require 'subr-x)

(defgroup ruri nil
  "Ruri: Ruby-shaped scripting for Emacs."
  :group 'applications
  :prefix "ruri-")

(defcustom ruri-compiler-executable "ruri"
  "Executable that compiles `.ruri' source into Emacs Lisp.
Looked up on `exec-path'.  See `ruri-compiler-arguments' for how the
command line is assembled."
  :type 'string)

(defcustom ruri-compiler-arguments '("compile")
  "Arguments passed to `ruri-compiler-executable' before the file names.
The full invocation is EXECUTABLE ARGS... INPUT --output OUTPUT; the
input path and the --output flag are appended by `ruri-compile-file'."
  :type '(repeat string))

(defcustom ruri-compiler-environment nil
  "Additional process environment entries for the compiler, or nil.
Each entry is a string of the form \"NAME=VALUE\".  The development
configuration uses this to point BUNDLE_GEMFILE at the compiler
checkout's Gemfile."
  :type '(repeat string))

(defun ruri--read-source-file (prompt)
  "Prompt with PROMPT for a `.ruri' source file, defaulting to the buffer file."
  (let ((default (and buffer-file-name
                      (equal (file-name-extension buffer-file-name) "ruri")
                      buffer-file-name)))
    (read-file-name prompt nil default t nil
                    (lambda (name) (equal (file-name-extension name) "ruri")))))

(defun ruri--output-path (source)
  "Output path for SOURCE: `NAME.el' beside the source file."
  (concat (file-name-sans-extension source) ".el"))

(defun ruri--compile (source)
  "Compile SOURCE synchronously and return the generated `.el' path.
On a nonzero compiler exit, signal an error carrying the compiler
diagnostics; the previous output file is left untouched."
  (let* ((source (expand-file-name source))
         (output (ruri--output-path source))
         (executable (or (executable-find ruri-compiler-executable)
                         (user-error "ruri: compiler executable %S not found on exec-path (see `ruri-compiler-executable')"
                                     ruri-compiler-executable)))
         (arguments (append ruri-compiler-arguments
                            (list source "--output" output))))
    (with-temp-buffer
      (let* ((process-environment (append ruri-compiler-environment
                                          process-environment))
             (exit-code (apply #'call-process executable nil t nil arguments))
             (diagnostics (string-trim (buffer-string))))
        (if (zerop exit-code)
            (progn
              (message "ruri: compiled %s -> %s" source output)
              output)
          (error "ruri: compiling %s failed:\n%s" source diagnostics))))))

;;;###autoload
(defun ruri-compile-file (source)
  "Compile the Ruri source file SOURCE to `NAME.el' beside it.
Return the output path.  Interactively, prompt for a `.ruri' file."
  (interactive (list (ruri--read-source-file "Ruri source to compile: ")))
  (ruri--compile source))

;;;###autoload
(defun ruri-load-file (source)
  "Compile SOURCE and load the freshly generated `.el' file.
Compilation happens first; if it fails, nothing is loaded and the error
carries the compiler diagnostics.  Loading targets the exact `.el' path,
never a stale `.elc'."
  (interactive (list (ruri--read-source-file "Ruri source to load: ")))
  (load (ruri--compile source) nil t t))

(provide 'ruri)

;;; ruri.el ends here
