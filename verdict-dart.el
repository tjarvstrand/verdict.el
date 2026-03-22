;;; verdict-dart.el --- Dart runner for verdict -*- lexical-binding: t -*-
;;
;; Package-Requires: ((emacs "30.0") (verdict "0.1") (f "0.20"))

(require 'verdict)
(require 'treesit)
(require 'f)
(require 'yaml)

;;; Customization

(defun verdict-dart--debug-default (context)
  "Launch a debug session using dape if available.
CONTEXT is a plist; see `verdict-dart-debug-fn'."
  (if (require 'dape nil t)
      (verdict-dart--dape-debug context)
    (error "Install dape or set `verdict-dart-debug-fn' to enable debug mode")))

(defcustom verdict-dart-debug-fn #'verdict-dart--debug-default
  "Function to launch a dart test debug session.
Called with a single argument: a plist with keys
:project, :files, :names, :name, :runner (\"dart\" or \"flutter\").
The function should start a debug session (e.g. via dape or dap-mode).
The default uses dape if available, otherwise signals an error."
  :type 'function)

(defvar verdict-dart-flutter-packages '("flutter_test")
  "List of package names whose import indicates a Flutter test file.
When a test file imports any of these packages, `flutter test' is
used instead of `dart test'.")

;;; Internal State

(defvar verdict-dart--group-names (make-hash-table)
  "Map of dart group ID (integer) → full name string.")

(defvar verdict-dart--file-suite-ids (make-hash-table :test #'equal)
  "Map of file path → suite ID for the current run.")

(defvar verdict-dart--loading-tests (make-hash-table :test #'equal)
  "Map of loading-test ID → suite ID.")

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

;;; Module / Project Root

(defun verdict-dart--module-root ()
  "Return the module root by locating pubspec.yaml."
  (let ((dir (f-traverse-upwards
              (lambda (d) (f-exists-p (f-join d "pubspec.yaml")))
              (f-dirname buffer-file-name))))
    (unless dir
      (error "Could not find pubspec.yaml above %s" buffer-file-name))
    dir))


;;; Helpers

(defun verdict-dart--strip-parent-prefix (parent-name name)
  "Strip PARENT-NAME prefix (plus one space) from NAME if present."
  (let ((prefix (concat parent-name " ")))
    (if (string-prefix-p prefix name)
        (substring name (length prefix))
      name)))

(defun verdict-dart--innermost-group (group-ids)
  "Return the innermost known group ID from GROUP-IDS, or nil.
GROUP-IDS is a sequence (list or vector).
Skips root groups (those with empty names)."
  (seq-find (lambda (id)
              (--> (gethash id verdict-dart--group-names)
                   (not (string-empty-p it))))
            (reverse (seq-into group-ids 'list))))

(defun verdict-dart--resolve-test-id (test-id)
  "Return TEST-ID, or the suite ID if TEST-ID is a loading test."
  (or (gethash test-id verdict-dart--loading-tests) test-id))

(defun verdict-dart--url-to-file (url)
  "Convert a file:// URL to a local file path, or return nil."
  ;; Returns nil if url is nil
  (string-remove-prefix "file://" url))

;;; JSON → Event Translation

(defun verdict-dart--handle-event (event)
  "Dispatch a parsed dart test EVENT (plist) to `verdict-event'.
EVENT uses keyword keys, vectors for arrays, and :json-false for false."
  (pcase (plist-get event :type)
    ("start" nil)

    ("suite"
     (let* ((suite    (plist-get event :suite))
            (suite-id (plist-get suite :id))
            (path     (plist-get suite :path)))
       (puthash path suite-id verdict-dart--file-suite-ids)
       (verdict-event (list :type  :group
                            :id    suite-id
                            :label (file-name-nondirectory path)
                            :file  path))))

    ("group"
     (let* ((group       (plist-get event :group))
            (parent-id   (plist-get group :parentID))
            (id          (plist-get group :id))
            (name        (plist-get group :name))
            (parent-name (and (numberp parent-id)
                              (gethash parent-id verdict-dart--group-names))))
       ;; Always store full name so children can strip it.
       (when (numberp id)
         (puthash id name verdict-dart--group-names))
       (when (and parent-id (not (string-empty-p name)))
         (let ((label (if parent-name
                          (verdict-dart--strip-parent-prefix parent-name name)
                        name)))
           (verdict-event (list :type       :group
                                :id         id
                                :parent-id  (if-let ((pname (gethash parent-id verdict-dart--group-names))
                                                     ((not (string-empty-p pname))))
                                                parent-id
                                              (plist-get group :suiteID))
                                :name       name
                                :label      (unless (string= label name) label)
                                :test-count (plist-get group :testCount)
                                :line       (plist-get group :line)
                                :file       (verdict-dart--url-to-file (plist-get group :url))))))))

    ("testStart"
     (let* ((test      (plist-get event :test))
            (id        (plist-get test :id))
            (name      (plist-get test :name))
            (suite-id  (plist-get test :suiteID))
            (group-ids (plist-get test :groupIDs)))
       (if (seq-empty-p group-ids)
           (puthash id suite-id verdict-dart--loading-tests)
         (let* ((parent-name (gethash (seq-elt group-ids (1- (length group-ids)))
                                      verdict-dart--group-names))
                (label (if parent-name
                           (verdict-dart--strip-parent-prefix parent-name name)
                         name)))
           (verdict-event (list :type      :test-start
                                :id        id
                                :parent-id (or (verdict-dart--innermost-group group-ids) suite-id)
                                :name      name
                                :label     (unless (string= label name) label)
                                :line      (plist-get test :line)
                                :file      (verdict-dart--url-to-file (plist-get test :url))))))))

    ("print"
     (verdict-event (list :type     :log
                          :severity 'info
                          :id       (verdict-dart--resolve-test-id (plist-get event :testID))
                          :message  (plist-get event :message))))

    ("error"
     (verdict-event (list :type     :log
                          :severity 'error
                          :id       (verdict-dart--resolve-test-id (plist-get event :testID))
                          :message  (concat (plist-get event :error) "\n" (plist-get event :stackTrace)))))

    ("testDone"
     (let* ((raw-id  (plist-get event :testID))
            (loading (gethash raw-id verdict-dart--loading-tests))
            (id      (or loading raw-id))
            (result  (if (eq (plist-get event :skipped) t)
                         'skipped
                       (pcase (plist-get event :result)
                         ("success" 'passed)
                         ("error"   (if loading 'error 'failed))
                         (_         'error)))))
       ;; Skip successful loading tests — suite status is aggregated from children
       (unless (and loading (eq result 'passed))
         (verdict-event (list :type   :test-done
                              :id     id
                              :result result)))))

    ("done"
     (verdict-event (list :type    :done
                          :success (plist-get event :success))))

    (_ nil)))

(defun verdict-dart--handle-line (line)
  "Parse one JSON LINE from `dart test -r json' and dispatch to `verdict-event'."
  (condition-case err
      (unless (string-empty-p line)
        (verdict-dart--handle-event
         (json-parse-string line :object-type 'plist :false-object :json-false :null-object nil)))
    (error
     (message "verdict-dart: error parsing line: %s\n%s" line (error-message-string err)))))

;;; Context and Command Functions

(defun verdict-dart--context-fn (scope &optional file-tests)
  "Return a context plist for SCOPE, reading from the current buffer.
When FILE-TESTS is provided (an alist of (FILE . (NAME ...)) entries),
use it instead of deriving from the buffer.
Resets per-run parse state as a side effect."
  (setq verdict-dart--group-names    (make-hash-table)
        verdict-dart--file-suite-ids (make-hash-table :test #'equal)
        verdict-dart--loading-tests  (make-hash-table :test #'equal))
  (if file-tests
      (let ((files (mapcar #'car file-tests))
            (names (mapcan #'cdr (mapcar #'copy-sequence file-tests))))
        (list :project (verdict-dart--module-root)
              :files   files
              :names   names
              :name    (car (or names files))))
    (let* ((buf-file  (buffer-file-name))
           (test-name (pcase scope
                        (:at-point (plist-get (or (verdict-dart--test-at-point)
                                                  (error "No test found at point"))
                                              :name))
                        (:group    (plist-get (car (or (verdict-dart--enclosing-calls)
                                                       (error "No group or test found at point")))
                                              :name))
                        (_ nil))))
      (list :project (pcase scope
                       (:project (funcall verdict-project-root-fn))
                       (_        (verdict-dart--module-root)))
            :files   (unless (memq scope '(:module :project)) (list buf-file))
            :names   (when test-name (list test-name))
            :name    (or test-name (when buf-file (file-name-nondirectory buf-file)))))))

;;; Flutter Detection

(defun verdict-dart--flutter-project-p (project-dir)
  "Return non-nil if PROJECT-DIR's pubspec.yaml depends on Flutter.
Checks for a flutter SDK dependency or a dev-dependency on any
package in `verdict-dart-flutter-packages'."
  (let* ((yaml (yaml-parse-string
                (with-temp-buffer
                  (insert-file-contents (f-join project-dir "pubspec.yaml"))
                  (buffer-string))
                :object-type 'alist))
         (deps     (alist-get 'dependencies yaml))
         (dev-deps (alist-get 'dev_dependencies yaml)))
    (or (alist-get 'sdk (alist-get 'flutter deps))
        (seq-find (lambda (pkg) (alist-get (intern pkg) dev-deps))
                  verdict-dart-flutter-packages))))

(defun verdict-dart--use-flutter-p (context)
  "Return non-nil if CONTEXT indicates Flutter should be used.
Checks the project's pubspec.yaml for Flutter dependencies."
  (verdict-dart--flutter-project-p (plist-get context :project)))

(defun verdict-dart--pcre-quote (string)
  "Escape PCRE metacharacters in STRING."
  (replace-regexp-in-string "[\\\\^$.|?*+()\\[\\]{}]" "\\\\\\&" string))

(defun verdict-dart--name-filter-args (names)
  "Return command-line args to filter by NAMES, or nil."
  (when names
    (if (= (length names) 1)
        (list "--plain-name" (car names))
      (list "--name" (concat "^(" (mapconcat #'verdict-dart--pcre-quote names "|") ")$")))))

(defun verdict-dart--command-fn (context debug)
  "Build dart/flutter test command from CONTEXT and DEBUG flag.
Returns a plist with :command :directory :name."
  (let* ((files  (plist-get context :files))
         (names  (plist-get context :names))
         (runner (if (verdict-dart--use-flutter-p context) "flutter" "dart")))
    (if debug
        (let ((debug-context (plist-put (copy-sequence context) :runner runner)))
          (list :command   (lambda () (funcall verdict-dart-debug-fn debug-context))
                :directory (plist-get context :project)
                :name      (plist-get context :name)))
      (list :command   (append (list runner "test" "-r" "json")
                               (verdict-dart--name-filter-args names)
                               files)
            :directory (plist-get context :project)
            :name      (plist-get context :name)))))

;;; Backend Registration

(verdict-register-backend 'dart-ts-mode
                         #'verdict-dart--context-fn
                         #'verdict-dart--command-fn
                         #'verdict-dart--handle-line)

(add-hook 'dart-ts-mode-hook #'verdict-mode)

;;; Dape Integration

(defun verdict-dart--dape-debug (context)
  "Launch a dape debug session for a dart/flutter test.
CONTEXT is a plist with :project, :file, :names, :name, :runner."
  (let* ((runner    (plist-get context :runner))
         (files     (plist-get context :files))
         (_         (when (> (length files) 1)
                      (error "Debug mode supports only a single file")))
         (file      (car files))
         (names     (plist-get context :names))
         (flutter-p (string= runner "flutter"))
         (config    `(command ,runner
                      command-args ("debug_adapter" "--test")
                      command-cwd ,(plist-get context :project)
                      :type "dart"
                      :cwd "."
                      ,@(when file (list :program file))
                      ,@(when names
                          (list :args (vector "--plain-name" (car names))))
                      ,@(when flutter-p '(:toolArgs ["-d" "all"])))))
    (dape config)))

(with-eval-after-load 'dape
  (cl-defmethod dape-handle-event
    (_conn (_event (eql dart.testNotification)) body)
    "Forward Dart test notifications to verdict."
    (verdict-dart--handle-event body))

  (cl-defmethod dape-handle-event :after
    (_conn (_event (eql terminated)) _body)
    "Stop verdict when the dape session terminates."
    (when (eq verdict--run-state 'running)
      (verdict-stop))))

(provide 'verdict-dart)
;;; verdict-dart.el ends here
