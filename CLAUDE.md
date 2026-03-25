# Guidelines

- After editing Emacs Lisp code, always verify syntax by running:
  `emacs --batch --eval '(with-temp-buffer (insert-file-contents "<file>") (goto-char (point-min)) (condition-case err (while t (read (current-buffer))) (end-of-file (message "OK")) (error (message "ERROR: %s" err))))'`
  Do not rely on visual inspection alone.
