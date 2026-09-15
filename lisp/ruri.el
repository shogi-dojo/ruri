;;; ruri.el --- Compile and load Ruri (Ruby-shaped) extensions -*- lexical-binding: t; -*-

;; Version: 0.18.0
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
Looked up on variable `exec-path'.  See `ruri-compiler-arguments' for
how the command line is assembled."
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

(defcustom ruri-byte-compile-after-compile nil
  "When non-nil, byte-compile the generated `.el' after compiling.
`ruri-compile-file' then also produces a `.elc' beside it.  A
byte-compile failure reports the diagnostics but never destroys the
generated `.el'."
  :type 'boolean)

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

(defun ruri--compilation-buffer-name (source)
  "Buffer name for the compilation output of SOURCE."
  (concat "*Ruri compilation: "
          (file-name-nondirectory (directory-file-name (file-name-directory source)))
          "/" (file-name-nondirectory source) "*"))

(defun ruri--report-diagnostics (source diagnostics)
  "Show compiler DIAGNOSTICS for SOURCE in a `compilation-mode' buffer.
The diagnostics are GNU style (`FILE:LINE:COL: MESSAGE'), so the
built-in `gnu' error rule parses them and `next-error' jumps straight
to the failing source line.  The buffer is also displayed so the
failure is visible even when the error is raised."
  (with-current-buffer (get-buffer-create (ruri--compilation-buffer-name source))
    (let ((inhibit-read-only t))
      (erase-buffer)
      ;; The error parser skips the first buffer line, so the buffer
      ;; opens with a plain header instead of a diagnostic.
      (insert "Ruri compiler diagnostics for " source ":\n"
              diagnostics "\n")
      (goto-char (point-min)))
    (compilation-mode)
    (display-buffer (current-buffer))))

(defun ruri--compile (source)
  "Compile SOURCE synchronously and return the generated `.el' path.
On a nonzero compiler exit, show the GNU-style diagnostics in a
`compilation-mode' buffer (see `ruri--report-diagnostics') and signal
an error; the previous output file is left untouched."
  (let* ((source (expand-file-name source))
         (output (ruri--output-path source))
         (executable (or (executable-find ruri-compiler-executable)
                         (user-error "Ruri: compiler executable %S not found on exec-path (see `ruri-compiler-executable')"
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
              (message "Ruri: compiled %s -> %s" source output)
              output)
          (ruri--report-diagnostics source diagnostics)
          (error "Ruri: compiling %s failed (see `next-error' for the location)" source))))))

;;;###autoload
(defun ruri-compile-file (source)
  "Compile the Ruri source file SOURCE to `NAME.el' beside it.
Return the output path.  Interactively, prompt for a `.ruri' file.
With `ruri-byte-compile-after-compile' non-nil, the generated file is
byte-compiled as well."
  (interactive (list (ruri--read-source-file "Ruri source to compile: ")))
  (let ((output (ruri--compile source)))
    (when ruri-byte-compile-after-compile
      (ruri--byte-compile output))
    output))

(defun ruri--byte-compile (output)
  "Byte-compile the generated OUTPUT file.
Errors are reported as a user error naming the file; the `.el' itself
is always left intact."
  (let ((result (byte-compile-file output)))
    (unless (eq result t)
      (user-error "Ruri: byte-compiling %S failed; the generated file was kept"
                  output))))

;;;###autoload
(defun ruri-load-file (source)
  "Compile SOURCE and load the freshly generated `.el' file.
Compilation happens first; if it fails, nothing is loaded and the error
carries the compiler diagnostics.  Loading targets the exact `.el' path,
never a stale `.elc'."
  (interactive (list (ruri--read-source-file "Ruri source to load: ")))
  (load (ruri--compile source) nil t t))

(defvar ruri-font-lock-keywords
  (list
   (cons
    "\\<\\(assign\\|catch\\|command\\|cons\\|constant\\|custom\\|doc\\|fn\\|function\\|insert\\|interactive\\|keyword\\|let\\|list\\|provide\\|quasiquote\\|quote\\|require\\|splice\\|throw\\|unquote\\|variable_local\\|variable\\|var\\|with_current_buffer\\)\\>"
    'font-lock-keyword-face)
   (cons "\\<el\\>" 'font-lock-builtin-face))
  "Ruri vocabulary highlighted by `ruri-mode' in addition to Ruby's.
The first entry matches the Ruri definition and template forms; the
second matches the `el' namespace used for explicit Emacs Lisp calls.")

;;;###autoload
(define-derived-mode ruri-mode ruby-mode "Ruri"
  "Major mode for editing Ruri (Ruby-shaped Emacs Lisp) source files.
Ruri source is valid Ruby syntax, so inheritance from `ruby-mode'
provides indentation, comment syntax, and symbol handling; the Ruri
vocabulary (command, function, let, assign, and friends) is
highlighted on top through `ruri-font-lock-keywords'.  Compile the
buffer's file with \\[ruri-compile-file], or enable
`ruri-compile-on-save-mode' to compile after every save."
  (font-lock-add-keywords nil ruri-font-lock-keywords 'append))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ruri\\'" . ruri-mode))

;;;###autoload
(define-minor-mode ruri-compile-on-save-mode
  "Compile the current `.ruri' file after every save.
The file is compiled with `ruri-compile-file'; a failed compilation
shows the diagnostics in a `compilation-mode' buffer and does not
touch the previous generated output.  The mode is off by default and
must be enabled explicitly, per buffer, or through a hook such as
`ruri-mode-hook'."
  :lighter " Ruri:Compile"
  (if ruri-compile-on-save-mode
      (add-hook 'after-save-hook #'ruri--compile-on-save nil t)
    (remove-hook 'after-save-hook #'ruri--compile-on-save t)))

(defun ruri--compile-on-save ()
  "After-save hook of `ruri-compile-on-save-mode'.
Compiles the buffer's file when it is a `.ruri' file; otherwise the
hook does nothing."
  (when (and buffer-file-name
             (equal (file-name-extension buffer-file-name) "ruri"))
    (ruri-compile-file buffer-file-name)))

(provide 'ruri)

;;; ruri.el ends here
