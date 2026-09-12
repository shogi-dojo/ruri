;;; greet.el --- Friendly greetings for Emacs -*- lexical-binding: t; -*-

;; Author: Ruri Example <ruri@example.com>
;; Version: 1.0
;; Keywords: convenience

;;; Commentary:

;; A minimal package used to demonstrate byte-identical conversion from
;; Ruri source; see examples/greet.ruri.

;;; Code:

(require 'subr-x)

(defvar greet-name "Emacs"
  "Name used in greetings.")

(defconst greet-version "1.0"
  "Version of the greet package.")

(defcustom greet-style 'plain
  "How greetings are formatted."
  :type 'symbol)

(defun greet-hello ()
  "Say hello to the configured name."
  (interactive)
  (message "Hello, %s!" greet-name))

(defun greet-report ()
  "Report the package configuration."
  (interactive)
  (message "name=%S style=%S version=%S" greet-name greet-style greet-version))

(provide 'greet)
;;; greet.el ends here
