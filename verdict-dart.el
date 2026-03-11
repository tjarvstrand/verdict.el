;;; verdict-dart.el --- Dart runner for verdict -*- lexical-binding: t -*-
;;
;; Package-Requires: ((emacs "30.0") (verdict "0.1") (f "0.20"))

(require 'verdict)
(require 'treesit)
(require 'f)

;;; Internal State

(defvar verdict-dart--proc nil
  "Active dart test process.")

(defvar verdict-dart--partial ""
  "Partial line buffer for process output.")

(defvar verdict-dart--last-scope nil
  "Last run scope: :at-point :file :project.")

(defvar verdict-dart--last-file nil
  "Last run file path.")

(defvar verdict-dart--last-name nil
  "Last run test name.")

(defvar verdict-dart--last-debug nil
  "Last run debug flag.")

(defvar verdict-dart--group-names (make-hash-table)
  "Map of dart group ID (integer) → full name string.")

(defvar verdict-dart--file-suite-ids (make-hash-table :test #'equal)
  "Map of file path → suite ID for the current run.")

;;; Dart String Literal Parsing

(defconst verdict-dart--string-prefixes
  ;; Ordered longest-first so seq-find matches greedily
  '(("r\"\"\"" . 4) ("r'''"  . 4)
    ("\"\"\""  . 3) ("'''"   . 3)
    ("r\""     . 2) ("r'"    . 2)
    ("\""      . 1) ("'"     . 1))
  "Ordered list of (prefix . length) for Dart string literals.")

(defun verdict-dart--string-content (s)
  "Return the content of Dart string literal S, stripping quotes/prefixes."
  (when-let* ((pair (seq-find (lambda (p) (string-prefix-p (car p) s))
                              verdict-dart--string-prefixes))
              (prefix-len (cdr pair))
              (suffix-len (if (>= prefix-len 3)
                              ;; Triple-quoted: suffix length equals prefix without 'r'
                              (if (string-prefix-p "r" (car pair)) 3 prefix-len)
                            1))
              (inner-len  (- (length s) prefix-len suffix-len)))
    (when (>= inner-len 0)
      (substring s prefix-len (+ prefix-len inner-len)))))

;;; AST Walking

(defconst verdict-dart--test-call-kinds
  '("group" "test" "testWidgets")
  "Dart test function names recognized by verdict.")

(defun verdict-dart--ensure-parser ()
  "Create a dart treesit parser for the current buffer if needed."
  (unless (treesit-ready-p 'dart t)
    (error "Dart treesit grammar not available"))
  (treesit-parser-create 'dart))

(defun verdict-dart--call-info-from-node (node)
  "Extract call info from NODE if it is a recognized test/group call.
Returns (:kind KIND :name NAME :line LINE) or nil."
  (when (and node (string= (treesit-node-type node) "expression_statement"))
    (let* ((child (treesit-node-child node 0)))
      (when (and child (string= (treesit-node-type child) "identifier"))
        (let ((kind (treesit-node-text child t)))
          (when (member kind verdict-dart--test-call-kinds)
            (let* ((selector  (treesit-node-child node 1))
                   (arg-part  (and selector
                                   (string= (treesit-node-type selector) "selector")
                                   (treesit-node-child selector 0)))
                   (arguments (and arg-part
                                   (string= (treesit-node-type arg-part) "argument_part")
                                   (treesit-node-child arg-part 0)))
                   (first-arg (and arguments
                                   (string= (treesit-node-type arguments) "arguments")
                                   (treesit-node-child arguments 1)))
                   (str-node  (when first-arg
                                (if (string= (treesit-node-type first-arg) "string_literal")
                                    first-arg
                                  (treesit-node-child first-arg 0)))))
              (when (and str-node
                         (string= (treesit-node-type str-node) "string_literal"))
                (let* ((raw  (treesit-node-text str-node t))
                       (name (verdict-dart--string-content raw))
                       (line (treesit-node-start node)))
                  (when name
                    (list :kind kind
                          :name name
                          :line (line-number-at-pos line))))))))))))

(defun verdict-dart--enclosing-calls ()
  "Return list of call-infos from outermost to innermost enclosing test/group call."
  (verdict-dart--ensure-parser)
  (let* ((start-node (treesit-node-at (point) 'dart))
         (node       start-node)
         (results    nil))
    (while node
      (when-let ((info (verdict-dart--call-info-from-node node)))
        (push info results))
      (setq node (treesit-node-parent node)))
    results))

;;; Test-at-Point

(defun verdict-dart--test-at-point ()
  "Return (:file FILE :name NAME) for the test at point, or nil."
  (let* ((calls (verdict-dart--enclosing-calls))
         (has-test (seq-find (lambda (c)
                               (member (plist-get c :kind) '("test" "testWidgets")))
                             calls)))
    (when (and calls has-test)
      (let ((full-name (mapconcat (lambda (c) (plist-get c :name)) calls " ")))
        (list :file buffer-file-name :name full-name)))))

;;; Project Root

(defun verdict-dart--project-root ()
  "Return the project root by locating pubspec.yaml."
  (let ((dir (f-traverse-upwards
              (lambda (d) (f-exists-p (f-join d "pubspec.yaml")))
              (f-dirname buffer-file-name))))
    (unless dir
      (error "Could not find pubspec.yaml above %s" buffer-file-name))
    dir))

;;; Command Builder

(defun verdict-dart--command (scope file name _dir debug)
  "Build the dart test command for SCOPE, FILE, NAME, DEBUG."
  (when debug
    (error "verdict-dart: debug not yet supported"))
  (let ((cmd (list "dart" "test" "-r" "json")))
    (when name
      (setq cmd (append cmd (list "--plain-name" name))))
    (when file
      (setq cmd (append cmd (list file))))
    cmd))

;;; Helpers

(defun verdict-dart--strip-parent-prefix (parent-name name)
  "Strip PARENT-NAME prefix (plus one space) from NAME if present."
  (let ((prefix (concat parent-name " ")))
    (if (string-prefix-p prefix name)
        (substring name (length prefix))
      name)))

;;; JSON → Event Translation

(defun verdict-dart--handle-line (line &optional file)
  "Parse one JSON LINE from `dart test -r json' and dispatch to `verdict-event'.
FILE is the test file associated with this process, used for error attribution."
  (condition-case err
      (unless (string-empty-p line)
        (let* ((ev   (json-parse-string line :object-type 'hash-table :array-type 'list))
               (type (gethash "type" ev)))
          (pcase type
            ("start" nil)

            ("suite"
             (let* ((suite    (gethash "suite" ev))
                    (suite-id (gethash "id" suite))
                    (path     (gethash "path" suite)))
               (puthash path suite-id verdict-dart--file-suite-ids)
               (verdict-event (list :type      :group
                                    :id        suite-id
                                    :name      (file-name-nondirectory path)
                                    :file      path))))

            ("group"
             (let* ((group       (gethash "group" ev))
                    (parent-id   (gethash "parentID" group))
                    (id          (gethash "id" group))
                    (name        (gethash "name" group))
                    (parent-name (and (numberp parent-id)
                                      (gethash parent-id verdict-dart--group-names)))
                    (label       (if parent-name
                                     (verdict-dart--strip-parent-prefix parent-name name)
                                   name)))
               ;; Always store full name so children can strip it.
               (when (numberp id)
                 (puthash id name verdict-dart--group-names))
               ;; Skip root groups (null parentID or empty name)
               (unless (or (eq parent-id :null)
                           (and (stringp name) (string-empty-p name)))
                 (verdict-event (list :type       :group
                                      :id         id
                                      :file-id    (gethash "suiteID" group)
                                      :parent-id  (if (eq parent-id :null) nil parent-id)
                                      :name       label
                                      :test-count (gethash "testCount" group)
                                      :line       (gethash "line" group)
                                      :url        (gethash "url" group))))))

            ("testStart"
             (let* ((test        (gethash "test" ev))
                    (group-ids   (gethash "groupIDs" test))
                    (name        (gethash "name" test))
                    (parent-name (when (and group-ids (> (length group-ids) 0))
                                   (gethash (aref group-ids (1- (length group-ids)))
                                            verdict-dart--group-names)))
                    (label       (if parent-name
                                     (verdict-dart--strip-parent-prefix parent-name name)
                                   name)))
               (verdict-event (list :type      :test-start
                                    :id        (gethash "id" test)
                                    :file-id   (gethash "suiteID" test)
                                    :group-ids group-ids
                                    :name      label
                                    :line      (gethash "line" test)
                                    :url       (gethash "url" test)))))

            ("print"
             (verdict-event (list :type         :log
                                  :severity     'info
                                  :id           (gethash "testID" ev)
                                  :message      (gethash "message" ev))))

            ("error"
             (verdict-event (list :type        :log
                                  :severity    'error
                                  :id          (gethash "testID" ev)
                                  :message     (concat (gethash "error" ev) "\n" (gethash "stackTrace" ev)))))

            ("testDone"
             (let* ((result (if (eq (gethash "skipped" ev) t)
                                'skipped
                              (pcase (gethash "result" ev)
                                ("success" 'passed)
                                ("failure" 'failed)
                                (_         'error))
                              )))
               (verdict-event (list :type    :test-done
                                    :id      (gethash "testID" ev)
                                    :result  result))))

            ("done"
             (verdict-event (list :type    :done
                                  :success (gethash "success" ev))))

            (_ nil))))
    (error
     (let ((suite-id (and file (gethash file verdict-dart--file-suite-ids))))
       (if suite-id
           (verdict-event (list :type     :log
                                :severity 'error
                                :id       suite-id
                                :message  line))
         (message "verdict-dart: error parsing line: %s\n%s" line (error-message-string err)))))))

;;; Process Infrastructure

(defun verdict-dart--filter (proc chunk)
  "Process filter: accumulate CHUNK and handle complete lines."
  (let* ((file  (process-get proc :verdict-file))
         (full  (concat verdict-dart--partial chunk))
         (parts (split-string full "\n"))
         (rest  (car (last parts))))
    (setq verdict-dart--partial rest)
    (dolist (line (butlast parts))
      (verdict-dart--handle-line line file))))

(defun verdict-dart--sentinel (proc event)
  "Process sentinel: flush partial buffer and finalize state."
  (let ((file (process-get proc :verdict-file)))
    (unless (string-empty-p verdict-dart--partial)
      (verdict-dart--handle-line verdict-dart--partial file)
      (setq verdict-dart--partial "")))
  (when (eq proc verdict-dart--proc)
    (verdict-stop))
  (message "verdict: process %s" (string-trim event)))

;;; Internal Run

(defun verdict-dart--run (scope file name debug)
  "Start a dart test run for SCOPE with FILE, NAME, DEBUG."
  (setq verdict-dart--last-scope scope
        verdict-dart--last-file  file
        verdict-dart--last-name  name
        verdict-dart--last-debug debug)
  (when (process-live-p verdict-dart--proc)
    (kill-process verdict-dart--proc))
  (setq verdict-dart--partial ""
        verdict-dart--group-names (make-hash-table)
        verdict-dart--file-suite-ids (make-hash-table :test #'equal))
  (verdict-start scope name)
  (let* ((project-root (verdict-dart--project-root))
         (cmd          (verdict-dart--command scope file name project-root debug))
         (default-directory project-root))
    (setq verdict-dart--proc
          (make-process
           :name              "verdict-dart"
           :command           cmd
           :connection-type   'pty
           :filter            #'verdict-dart--filter
           :sentinel          #'verdict-dart--sentinel
           :noquery           t))
    (process-put verdict-dart--proc :verdict-file file)
    (message "verdict: running %s" (string-join cmd " "))
    (message "verdict: in %s" project-root)))

;;; Public Commands

(defun verdict-run-at-point ()
  "Run the test at point."
  (interactive)
  (let ((info (or (verdict-dart--test-at-point)
                  (error "No test found at point"))))
    (verdict-dart--run :at-point
                       (plist-get info :file)
                       (plist-get info :name)
                       nil)))

(defun verdict-run-file ()
  "Run all tests in the current file."
  (interactive)
  (verdict-dart--run :file buffer-file-name nil nil))

(defun verdict-run-project ()
  "Run all tests in the project."
  (interactive)
  (verdict-dart--run :project nil nil nil))

(defun verdict-debug-at-point ()
  "Debug the test at point."
  (interactive)
  (let ((info (or (verdict-dart--test-at-point)
                  (error "No test found at point"))))
    (verdict-dart--run :at-point
                       (plist-get info :file)
                       (plist-get info :name)
                       t)))

(defun verdict-rerun ()
  "Rerun the last test run."
  (interactive)
  (unless verdict-dart--last-scope
    (error "No previous verdict run to repeat"))
  (verdict-dart--run verdict-dart--last-scope
                     verdict-dart--last-file
                     verdict-dart--last-name
                     verdict-dart--last-debug))

;;; Keybindings

(with-eval-after-load 'dart-ts-mode
  (define-key dart-ts-mode-map (kbd "C-c v t") #'verdict-run-at-point)
  (define-key dart-ts-mode-map (kbd "C-c v f") #'verdict-run-file)
  (define-key dart-ts-mode-map (kbd "C-c v p") #'verdict-run-project)
  (define-key dart-ts-mode-map (kbd "C-c v d") #'verdict-debug-at-point)
  (define-key dart-ts-mode-map (kbd "C-c v r") #'verdict-rerun))

(provide 'verdict-dart)
;;; verdict-dart.el ends here
