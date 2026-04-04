;;; verdict-buttercup.el --- Buttercup backend for verdict -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'verdict)
(require 'project)

;;; Parse state

(defvar verdict-buttercup--suite-stack nil
  "Stack of (id . indentation-depth) for tracking open suites.")

(defvar verdict-buttercup--id-counter 0
  "Counter for generating unique node IDs per run.")

(defvar verdict-buttercup--state 'normal
  "Parser state: one of `normal', `failure', or `done'.")

(defvar verdict-buttercup--failure-target nil
  "ID of the node currently receiving failure log lines, or nil.")

(defvar verdict-buttercup--failure-header-seen nil
  "Whether the first (header) line of the current failure block has been skipped.")

(defvar verdict-buttercup--failed-ids nil
  "Ordered list of IDs of specs that failed, used to route failure details.")

;;; Helpers

(defun verdict-buttercup--reset ()
  (setq verdict-buttercup--suite-stack         nil
        verdict-buttercup--id-counter          0
        verdict-buttercup--state               'normal
        verdict-buttercup--failure-target      nil
        verdict-buttercup--failure-header-seen nil
        verdict-buttercup--failed-ids          nil))

(defun verdict-buttercup--next-id ()
  (cl-incf verdict-buttercup--id-counter))

(defun verdict-buttercup--parent-id ()
  "Return the ID of the innermost open suite, or nil."
  (caar verdict-buttercup--suite-stack))

(defun verdict-buttercup--pop-to-depth (depth)
  "Pop suite stack entries at DEPTH or deeper."
  (while (and verdict-buttercup--suite-stack
              (>= (cdar verdict-buttercup--suite-stack) depth))
    (pop verdict-buttercup--suite-stack)))

(defun verdict-buttercup--enter-next-failure ()
  "Advance to the next queued failed spec for log attribution."
  (setq verdict-buttercup--failure-target      (pop verdict-buttercup--failed-ids)
        verdict-buttercup--failure-header-seen nil))

;;; Spec line parser

(defconst verdict-buttercup--timing-re
  " ([0-9]+\\(?:\\.[0-9]+\\)?ms)$"
  "Regex suffix matching a buttercup timing like \" (0.07ms)\".")

(defun verdict-buttercup--parse-spec-line (text)
  "Return (name . status) if TEXT is a spec result line, else nil."
  (cond
   ((string-match (concat "\\(.*\\)  FAILED" verdict-buttercup--timing-re) text)
    (cons (match-string 1 text) 'failed))
   ((string-match (concat "\\(.*\\)  (PENDING:[^)]*)" verdict-buttercup--timing-re) text)
    (cons (match-string 1 text) 'skipped))
   ((string-match (concat "\\(.*\\)" verdict-buttercup--timing-re) text)
    (cons (match-string 1 text) 'passed))
   (t nil)))

;;; Line handler

(defun verdict-buttercup--line-handler (line)
  "Parse LINE of buttercup batch output and emit verdict events."
  (cond
   ;; ===... separates failure detail blocks
   ((string-match-p "^=\\{2,\\}$" line)
    (pcase verdict-buttercup--state
      ('normal
       (setq verdict-buttercup--state 'failure)
       (verdict-buttercup--enter-next-failure))
      ('failure
       (if verdict-buttercup--failed-ids
           (verdict-buttercup--enter-next-failure)
         (setq verdict-buttercup--state 'done)))))

   ;; "Ran N specs..." — end of run, regardless of state
   ((string-match-p "^Ran [0-9]+" line)
    (verdict-event '(:type :done)))

   ;; Failure detail lines — first non-empty line is the header (skip it),
   ;; subsequent non-empty lines are the traceback
   ((eq verdict-buttercup--state 'failure)
    (unless (string-empty-p line)
      (if verdict-buttercup--failure-header-seen
          (when verdict-buttercup--failure-target
            (verdict-event (list :type     :log
                                 :id       verdict-buttercup--failure-target
                                 :severity 'error
                                 :message  line)))
        (setq verdict-buttercup--failure-header-seen t))))

   ;; Normal spec/suite output
   ((and (eq verdict-buttercup--state 'normal)
         (string-match "^\\( *\\)\\(.+\\)$" line))
    (let* ((depth  (length (match-string 1 line)))
           (text   (match-string 2 line))
           (parsed (verdict-buttercup--parse-spec-line text)))
      (verdict-buttercup--pop-to-depth depth)
      (cond
       (parsed
        (let ((id (verdict-buttercup--next-id)))
          (verdict-event (list :type      :test-start
                               :id        id
                               :name      (car parsed)
                               :parent-id (verdict-buttercup--parent-id)
                               :file      nil
                               :line      nil))
          (verdict-event (list :type   :test-done
                               :id     id
                               :result (cdr parsed)))
          (when (eq (cdr parsed) 'failed)
            (setq verdict-buttercup--failed-ids
                  (append verdict-buttercup--failed-ids (list id))))))
       ;; Suite heading — skip the "Running N specs." sentinel
       ((not (string-match-p "^Running [0-9]+ specs\\." text))
        (let ((id (verdict-buttercup--next-id)))
          (verdict-event (list :type      :group
                               :id        id
                               :name      text
                               :parent-id (verdict-buttercup--parent-id)
                               :file      nil
                               :line      nil))
          (push (cons id depth) verdict-buttercup--suite-stack))))))))

;;; Context and Command Functions

(defun verdict-buttercup--emacs-executable ()
  "Return the path to the running Emacs executable."
  (expand-file-name invocation-name invocation-directory))

(defun verdict-buttercup--load-path-args ()
  "Return a list of \"-L\" flags for each entry in `load-path'."
  (apply #'append (mapcar (lambda (d) (list "-L" d)) load-path)))

(defun verdict-buttercup--context-fn (scope)
  "Return a context plist for SCOPE, reading from the current buffer."
  (verdict-buttercup--reset)
  (let ((file (buffer-file-name))
        (root (or (when-let ((proj (project-current)))
                    (project-root proj))
                  default-directory)))
    (when (and (not (eq scope :project)) (not file))
      (error "No file associated with current buffer"))
    (list :file file :project root)))

(defun verdict-buttercup--command-fn (context _debug)
  "Return a command plist for running buttercup with CONTEXT."
  (let* ((file    (plist-get context :file))
         (root    (plist-get context :project))
         (lp-args (verdict-buttercup--load-path-args)))
    (if file
        (list :command   `(,(verdict-buttercup--emacs-executable) "--batch"
                           ,@lp-args
                           "--eval" "(setq buttercup-color nil)"
                           "-l" ,file
                           "-f" "buttercup-run")
              :directory root
              :name      (file-name-nondirectory file))
      (let ((test-dir (expand-file-name "test" root)))
        (list :command   `(,(verdict-buttercup--emacs-executable) "--batch"
                           ,@lp-args
                           "--eval" "(setq buttercup-color nil)"
                           "-f" "buttercup-run-discover"
                           ,(if (file-directory-p test-dir) test-dir "."))
              :directory root
              :name      (file-name-nondirectory (directory-file-name root)))))))

;;; Setup

(defun verdict-buttercup-setup ()
  "Register the buttercup backend with verdict for `emacs-lisp-mode' buffers."
  (interactive)
  (verdict-register-backend 'emacs-lisp-mode
                             #'verdict-buttercup--context-fn
                             #'verdict-buttercup--command-fn
                             #'verdict-buttercup--line-handler))

(provide 'verdict-buttercup)
;;; verdict-buttercup.el ends here
