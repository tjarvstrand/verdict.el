;;; verdict-dart.el --- Dart runner for verdict -*- lexical-binding: t -*-
;;
;; Package-Requires: ((emacs "30.0") (verdict "0.1") (f "0.20"))

(require 'verdict)
(require 'treesit)
(require 'f)

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
  (let ((name-args (when name (list "--plain-name" name)))
        (file-args (when file (list file))))
    (append (list "dart" "test" "-r" "json") name-args file-args)))

;;; Helpers

(defun verdict-dart--strip-parent-prefix (parent-name name)
  "Strip PARENT-NAME prefix (plus one space) from NAME if present."
  (let ((prefix (concat parent-name " ")))
    (if (string-prefix-p prefix name)
        (substring name (length prefix))
      name)))

(defun verdict-dart--innermost-group (group-ids)
  "Return the innermost known group ID from GROUP-IDS, or nil.
Skips root groups (those with empty names)."
  (-first (lambda (id)
            (--> (gethash id verdict-dart--group-names)
                 (not (string-empty-p it))))
          (reverse group-ids)))

(defun verdict-dart--resolve-test-id (test-id)
  "Return TEST-ID, or the suite ID if TEST-ID is a loading test."
  (or (gethash test-id verdict-dart--loading-tests) test-id))

(defun verdict-dart--url-to-file (url)
  "Convert a file:// URL to a local file path, or return nil."
  ;; Returns nil if url is nil
  (string-remove-prefix "file://" url))

;;; JSON → Event Translation

(defun verdict-dart--handle-line (line)
  "Parse one JSON LINE from `dart test -r json' and dispatch to `verdict-event'."
  (condition-case err
      (unless (string-empty-p line)
        (let* ((ev   (json-parse-string line :object-type 'hash-table :array-type 'list :null-object nil))
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
               (when (and parent-id (not (string-empty-p name)))
                 (let ((suite-id (gethash "suiteID" group)))
                   (verdict-event (list :type       :group
                                        :id         id
                                        :parent-id  (if-let ((pname (gethash parent-id verdict-dart--group-names))
                                                             ((not (string-empty-p pname))))
                                                        parent-id
                                                      suite-id)
                                        :name       label
                                        :test-count (gethash "testCount" group)
                                        :line       (gethash "line" group)
                                        :file       (verdict-dart--url-to-file (gethash "url" group))))))))

            ("testStart"
             (let* ((test        (gethash "test" ev))
                    (id          (gethash "id" test))
                    (name        (gethash "name" test))
                    (suite-id    (gethash "suiteID" test)))
               (if (string-match-p "^loading " name)
                   (puthash id suite-id verdict-dart--loading-tests)
                 (let* ((group-ids   (gethash "groupIDs" test))
                        (parent-id  (or (verdict-dart--innermost-group group-ids) suite-id))
                        (parent-name (-> group-ids
                                         last
                                         car
                                         (gethash verdict-dart--group-names)))
                        (label       (if parent-name
                                         (verdict-dart--strip-parent-prefix parent-name name)
                                       name)))
                   (verdict-event (list :type      :test-start
                                        :id        id
                                        :parent-id parent-id
                                        :name      label
                                        :line      (gethash "line" test)
                                        :file      (verdict-dart--url-to-file (gethash "url" test))))))))

            ("print"
             (let ((id (verdict-dart--resolve-test-id (gethash "testID" ev))))
               (verdict-event (list :type         :log
                                    :severity     'info
                                    :id           id
                                    :message      (gethash "message" ev)))))

            ("error"
             (let ((id (verdict-dart--resolve-test-id (gethash "testID" ev))))
               (verdict-event (list :type        :log
                                    :severity    'error
                                    :id          id
                                    :message     (concat (gethash "error" ev) "\n" (gethash "stackTrace" ev))))))

            ("testDone"
             (let* ((raw-id  (gethash "testID" ev))
                    (loading (gethash raw-id verdict-dart--loading-tests))
                    (id      (or loading raw-id))
                    (result  (if (eq (gethash "skipped" ev) t)
                                 'skipped
                               (pcase (gethash "result" ev)
                                 ("success" 'passed)
                                 ("failure" 'failed)
                                 (_         'error)))))
               ;; Skip successful loading tests — suite status is aggregated from children
               (unless (and loading (eq result 'passed))
                 (verdict-event (list :type    :test-done
                                      :id      id
                                      :result  result)))))

            ("done"
             (verdict-event (list :type    :done
                                  :success (gethash "success" ev))))

            (_ nil))))
    (error
     (message "verdict-dart: error parsing line: %s\n%s" line (error-message-string err)))))

;;; Command Function

(defun verdict-dart--command-fn (scope)
  "Build dart test command for SCOPE. Returns plist with :command :directory :name.
Called in user's original buffer context so buffer-file-name and point are available."
  (setq verdict-dart--group-names    (make-hash-table)
        verdict-dart--file-suite-ids (make-hash-table :test #'equal)
        verdict-dart--loading-tests  (make-hash-table :test #'equal))
  (let* ((project-root (verdict-dart--project-root))
         (file buffer-file-name)
         (name (pcase scope
                 (:at-point (plist-get (or (verdict-dart--test-at-point)
                                           (error "No test found at point"))
                                       :name))
                 (:group    (plist-get (car (or (verdict-dart--enclosing-calls)
                                                (error "No group or test found at point")))
                                       :name))
                 (:file     (file-name-nondirectory file))
                 (:project  nil)))
         (test-file (unless (eq scope :project) file))
         (test-name (when (memq scope '(:at-point :group)) name)))
    (list :command   (verdict-dart--command scope test-file test-name project-root nil)
          :directory project-root
          :name      name)))

;;; Backend Registration

(verdict-register-backend 'dart-ts-mode #'verdict-dart--command-fn #'verdict-dart--handle-line)

(add-hook 'dart-ts-mode-hook #'verdict-mode)

(provide 'verdict-dart)
;;; verdict-dart.el ends here
