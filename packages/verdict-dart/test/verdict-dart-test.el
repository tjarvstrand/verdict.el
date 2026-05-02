;;; verdict-dart-test.el --- Integration tests for verdict-dart.el -*- lexical-binding: t -*-

(require 'buttercup)
(require 'verdict)
(require 'verdict-dart)

;;; Helpers

(defconst verdict-dart-test--dir
  (expand-file-name "resources/dart"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Root of the dart test resource project.")

(defconst verdict-dart-test--fixtures-dir
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing pre-generated dart test JSON fixture files.")

(defun verdict-dart-test-generate-fixtures ()
  "Regenerate JSON fixture files by running dart test on each resource file.
Run this interactively whenever dart_test.dart or the resource files change."
  (interactive)
  (unless (executable-find "dart")
    (error "dart not found on PATH"))
  (make-directory verdict-dart-test--fixtures-dir t)
  (dolist (file '("dart_test" "fails_to_load" "fails_during_setup"
                  "fails_during_setup_all" "fails_no_tests"
                  "fails_during_teardown" "fails_during_teardown_all"))
    (let* ((src     (expand-file-name (concat "test/" file ".dart")
                                      verdict-dart-test--dir))
           (fixture (expand-file-name (concat file ".jsonl")
                                      verdict-dart-test--fixtures-dir))
           (default-directory verdict-dart-test--dir))
      (with-temp-file fixture
        (call-process "dart" nil t nil "test" "-r" "json" "--no-color" src))
      (message "verdict-dart-test: generated %s" (file-name-nondirectory fixture)))))

(defun verdict-dart-test--collect (fixture-name)
  "Feed the pre-generated FIXTURE-NAME.jsonl through `verdict-dart--handle-line'
and return the resulting verdict events in arrival order."
  (setq verdict-dart--group-names    (make-hash-table)
        verdict-dart--file-suite-ids (make-hash-table :test #'equal)
        verdict-dart--loading-tests  (make-hash-table :test #'equal))
  (let* ((fixture (expand-file-name (concat fixture-name ".jsonl")
                                    verdict-dart-test--fixtures-dir))
         (events  nil)
         (capture (lambda (ev) (push ev events))))
    (unless (file-exists-p fixture)
      (error "Fixture %s not found; run verdict-dart-test-generate-fixtures" fixture))
    (advice-add 'verdict-event :override capture)
    (unwind-protect
        (with-temp-buffer
          (insert-file-contents fixture)
          (goto-char (point-min))
          (while (not (eobp))
            (verdict-dart--handle-line
             (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
            (forward-line 1)))
      (advice-remove 'verdict-event capture))
    (nreverse events)))

(defun verdict-dart-test--by-type (events type)
  "Return events from EVENTS whose :type is TYPE."
  (seq-filter (lambda (ev) (eq (plist-get ev :type) type)) events))

(defun verdict-dart-test--find-start (events name)
  "Return the :test-start event whose display name matches NAME, or nil."
  (seq-find (lambda (ev)
              (and (eq (plist-get ev :type) :test-start)
                   (equal (or (plist-get ev :label) (plist-get ev :name)) name)))
            events))

(defun verdict-dart-test--find-group (events name)
  "Return the :group event whose display name matches NAME, or nil."
  (seq-find (lambda (ev)
              (and (eq (plist-get ev :type) :group)
                   (equal (or (plist-get ev :label) (plist-get ev :name)) name)))
            events))

(defun verdict-dart-test--result (events name)
  "Return the :result of the :test-done event for the test named NAME."
  (when-let* ((start   (verdict-dart-test--find-start events name))
              (id      (plist-get start :id))
              (done-ev (seq-find (lambda (ev)
                                   (and (eq (plist-get ev :type) :test-done)
                                        (equal (plist-get ev :id) id)))
                                 events)))
    (plist-get done-ev :result)))

(defun verdict-dart-test--find-log (events message)
  "Return the first :log event with :message MESSAGE, or nil."
  (seq-find (lambda (ev)
              (and (eq (plist-get ev :type) :log)
                   (equal (plist-get ev :message) message)))
            events))

(defun verdict-dart-test--log-goes-to-test-p (events message test-name)
  "Return t if the :log event with MESSAGE is attributed to the test named TEST-NAME."
  (let* ((log     (verdict-dart-test--find-log events message))
         (log-id  (and log (plist-get log :id)))
         (test-ev (verdict-dart-test--find-start events test-name))
         (test-id (and test-ev (plist-get test-ev :id))))
    (and log-id test-id (equal log-id test-id))))

(defun verdict-dart-test--log-goes-to-group-p (events message group-name)
  "Return t if the :log event with MESSAGE is attributed to the group named GROUP-NAME."
  (let* ((log      (verdict-dart-test--find-log events message))
         (log-id   (and log (plist-get log :id)))
         (group-ev (verdict-dart-test--find-group events group-name))
         (group-id (and group-ev (plist-get group-ev :id))))
    (and log-id group-id (equal log-id group-id))))

(defun verdict-dart-test--logs-for-test (events name)
  "Return :log events attributed to the test named NAME."
  (when-let* ((start (verdict-dart-test--find-start events name))
              (id    (plist-get start :id)))
    (seq-filter (lambda (ev)
                  (and (eq (plist-get ev :type) :log)
                       (equal (plist-get ev :id) id)))
                events)))

(defun verdict-dart-test--logs-for-group (events name)
  "Return :log events attributed to the group named NAME."
  (when-let* ((group (verdict-dart-test--find-group events name))
              (id    (plist-get group :id)))
    (seq-filter (lambda (ev)
                  (and (eq (plist-get ev :type) :log)
                       (equal (plist-get ev :id) id)))
                events)))

;;; verdict-dart--enclosing-calls

(defmacro verdict-dart-test--with-source (source &rest body)
  "Evaluate BODY in a temp buffer containing SOURCE.
A `[POINT]' marker in SOURCE is removed and `point' is left at its
location."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (goto-char (point-min))
     (when (search-forward "[POINT]" nil t)
       (replace-match "" t t))
     ,@body))

(describe "verdict-dart--enclosing-calls"
  (describe "regex fallback"
    (it "returns nil when point is outside any test/group"
      (verdict-dart-test--with-source
          "void main() {[POINT]\n  test('x', () {});\n}\n"
        (expect (verdict-dart--enclosing-calls-regex) :to-equal nil)))

    (it "returns the enclosing top-level test"
      (verdict-dart-test--with-source
          "void main() {\n  test('a top-level test', () {[POINT]});\n}\n"
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "test" :name "a top-level test" :line 2)))))

    (it "returns nested groups outermost first"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  group('outer', () {\n"
                  "    group('inner', () {\n"
                  "      test('leaf', () {[POINT]});\n"
                  "    });\n"
                  "  });\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "group" :name "outer" :line 2)
                            (:kind "group" :name "inner" :line 3)
                            (:kind "test"  :name "leaf"  :line 4)))))

    (it "handles single-quoted, double-quoted, and raw strings"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  group(\"dq\", () {\n"
                  "    group('sq', () {\n"
                  "      test(r'raw', () {[POINT]});\n"
                  "    });\n"
                  "  });\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "group" :name "dq"  :line 2)
                            (:kind "group" :name "sq"  :line 3)
                            (:kind "test"  :name "raw" :line 4)))))

    (it "handles triple-quoted strings (single, double, raw, multi-line)"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  group('''sq triple''', () {\n"
                  "    group(\"\"\"dq triple\"\"\", () {\n"
                  "      group(r'''raw triple''', () {\n"
                  "        test('''first\nsecond''', () {[POINT]});\n"
                  "      });\n"
                  "    });\n"
                  "  });\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "group" :name "sq triple"     :line 2)
                            (:kind "group" :name "dq triple"     :line 3)
                            (:kind "group" :name "raw triple"    :line 4)
                            (:kind "test"  :name "first\nsecond" :line 5)))))

    (it "ignores test( inside string literals"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  var s = \"test('decoy', () {})\";\n"
                  "  test('real', () {[POINT]});\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "test" :name "real" :line 3)))))

    (it "ignores test( inside line comments"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  // test('decoy', () {});\n"
                  "  test('real', () {[POINT]});\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "test" :name "real" :line 3)))))

    (it "ignores test( inside block comments"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  /* test('decoy', () {}); */\n"
                  "  test('real', () {[POINT]});\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "test" :name "real" :line 3)))))

    (it "skips calls whose first argument is not a string literal"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  group(name, () {\n"
                  "    test('real', () {[POINT]});\n"
                  "  });\n"
                  "}\n")
        (expect (verdict-dart--enclosing-calls-regex)
                :to-equal '((:kind "test" :name "real" :line 3))))))

  (describe "tree-sitter implementation"
    (before-all
      (unless (treesit-ready-p 'dart t)
        (signal 'buttercup-pending "Dart tree-sitter grammar not available")))

    (it "matches the regex fallback for nested groups"
      (verdict-dart-test--with-source
          (concat "void main() {\n"
                  "  group('outer', () {\n"
                  "    test('inner', () {[POINT]});\n"
                  "  });\n"
                  "}\n")
        (when (fboundp 'dart-mode) (dart-mode))
        (expect (verdict-dart--enclosing-calls-treesit)
                :to-equal (verdict-dart--enclosing-calls-regex))))))

;;; dart_test.dart

(defvar verdict-dart-test--main-events nil
  "Cached verdict events from running dart_test.dart.")

(describe "verdict-dart: dart_test.dart"
  (before-each
    (unless verdict-dart-test--main-events
      (setq verdict-dart-test--main-events
            (verdict-dart-test--collect "dart_test"))))

  (it "emits a :group event for the test file"
    (let ((file-group (verdict-dart-test--find-group verdict-dart-test--main-events "dart_test.dart")))
      (expect file-group :not :to-be nil)
      (expect (plist-get file-group :file)
              :to-equal "test/dart_test.dart")))

  (it "emits a :done event"
    (expect (verdict-dart-test--by-type verdict-dart-test--main-events :done)
            :not :to-be nil))

  (it "passes a top-level succeeding test"
    (expect (verdict-dart-test--result verdict-dart-test--main-events
                                       "a top-level test that succeeds")
            :to-be 'passed))

  (it "fails a top-level failing test"
    (expect (verdict-dart-test--result verdict-dart-test--main-events
                                       "a top-level test that fails")
            :to-be 'failed))

  (it "emits an error :log for a failing test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--main-events
                                                  "a top-level test that fails")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'error)))

  (it "skips a test marked skip"
    (expect (verdict-dart-test--result verdict-dart-test--main-events
                                       "a skipped test")
            :to-be 'skipped))

  (it "emits an info :log for print output"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--main-events
                                                  "a test with print output")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'info)
      (expect (plist-get (car logs) :message) :to-equal "hello from dart")))

  (it "emits a :group event for 'A group'"
    (expect (verdict-dart-test--find-group verdict-dart-test--main-events "A group")
            :not :to-be nil))

  (it "strips the group prefix from grouped test names"
    (expect (verdict-dart-test--find-start verdict-dart-test--main-events
                                           "a grouped test that succeeds")
            :not :to-be nil))

  (it "parents grouped tests under their group"
    (let* ((group    (verdict-dart-test--find-group verdict-dart-test--main-events "A group"))
           (group-id (plist-get group :id))
           (test     (verdict-dart-test--find-start verdict-dart-test--main-events
                                                    "a grouped test that succeeds")))
      (expect (plist-get test :parent-id) :to-equal group-id)))

  (it "emits :group events for nested groups"
    (expect (verdict-dart-test--find-group verdict-dart-test--main-events "Outer group")
            :not :to-be nil)
    (expect (verdict-dart-test--find-group verdict-dart-test--main-events "Inner group")
            :not :to-be nil))

  (it "parents inner group under outer group"
    (let* ((outer    (verdict-dart-test--find-group verdict-dart-test--main-events "Outer group"))
           (outer-id (plist-get outer :id))
           (inner    (verdict-dart-test--find-group verdict-dart-test--main-events "Inner group")))
      (expect (plist-get inner :parent-id) :to-equal outer-id)))

  (it "strips nested group prefix from nested test name"
    (expect (verdict-dart-test--find-start verdict-dart-test--main-events "a nested test")
            :not :to-be nil))

  (it "parents nested test under inner group"
    (let* ((inner    (verdict-dart-test--find-group verdict-dart-test--main-events "Inner group"))
           (inner-id (plist-get inner :id))
           (test     (verdict-dart-test--find-start verdict-dart-test--main-events "a nested test")))
      (expect (plist-get test :parent-id) :to-equal inner-id)))

  (it "passes the nested test"
    (expect (verdict-dart-test--result verdict-dart-test--main-events "a nested test")
            :to-be 'passed))

  (it "fails a test whose setUp throws"
    (expect (verdict-dart-test--result verdict-dart-test--main-events
                                       "First Test")
            :to-be 'failed))

  (it "attributes print inside a grouped test to that test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--main-events
                                                  "a grouped test with output")))
      (expect (length logs) :to-be 1)
      (expect (plist-get (car logs) :severity) :to-be 'info)
      (expect (plist-get (car logs) :message) :to-equal "log from grouped test")))

  (it "does not attribute the grouped test's print to the enclosing group"
    (let ((group-logs (verdict-dart-test--logs-for-group verdict-dart-test--main-events
                                                         "A group")))
      (expect (seq-find (lambda (ev)
                          (equal (plist-get ev :message) "log from grouped test"))
                        group-logs)
              :to-be nil)))

  (it "attributes print inside setUp to the test being set up"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--main-events
                                                  "test with setUp log")))
      (expect (length logs) :to-be 1)
      (expect (plist-get (car logs) :severity) :to-be 'info)
      (expect (plist-get (car logs) :message) :to-equal "log from setUp")))

  (it "does not attribute the setUp print to the enclosing group"
    (let ((group-logs (verdict-dart-test--logs-for-group verdict-dart-test--main-events
                                                         "A group with setUp log")))
      (expect (seq-find (lambda (ev)
                          (equal (plist-get ev :message) "log from setUp"))
                        group-logs)
              :to-be nil)))

  (it "attributes print inside a nested test to that test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--main-events
                                                  "a nested test")))
      (expect (length logs) :to-be 1)
      (expect (plist-get (car logs) :severity) :to-be 'info)
      (expect (plist-get (car logs) :message) :to-equal "log from nested test")))

  (it "does not attribute the nested test's print to the outer group"
    (let ((outer-logs (verdict-dart-test--logs-for-group verdict-dart-test--main-events
                                                         "Outer group")))
      (expect (seq-find (lambda (ev)
                          (equal (plist-get ev :message) "log from nested test"))
                        outer-logs)
              :to-be nil)))

  (it "does not attribute the nested test's print to the inner group"
    (let ((inner-logs (verdict-dart-test--logs-for-group verdict-dart-test--main-events
                                                         "Inner group")))
      (expect (seq-find (lambda (ev)
                          (equal (plist-get ev :message) "log from nested test"))
                        inner-logs)
              :to-be nil)))

  ;; Log attribution for lifecycle hooks and discovery-time code

  (it "attributes print in main() to the file group"
    (expect (verdict-dart-test--log-goes-to-group-p
             verdict-dart-test--main-events "log from main" "dart_test.dart")
            :to-be t))

  (it "attributes print in a group body to the file group"
    (expect (verdict-dart-test--log-goes-to-group-p
             verdict-dart-test--main-events "log from group body" "dart_test.dart")
            :to-be t))

  ;; Dart reports setUpAll/tearDownAll as synthetic tests "(setUpAll)"/"(tearDownAll)".
  ;; Logs are attributed to these synthetic tests, not to real tests in the group.

  ;; Dart reports setUpAll/tearDownAll as synthetic tests "(setUpAll)"/"(tearDownAll)".
  ;; Logs are attributed to these synthetic tests, not to real tests in the group.

  (it "attributes print in setUpAll to the synthetic (setUpAll) test"
    (let* ((log (verdict-dart-test--find-log verdict-dart-test--main-events "log from setUpAll"))
           (log-id (plist-get log :id))
           (start (seq-find (lambda (ev)
                              (and (eq (plist-get ev :type) :test-start)
                                   (equal (plist-get ev :id) log-id)))
                            verdict-dart-test--main-events)))
      (expect start :not :to-be nil)
      (expect (or (plist-get start :label) (plist-get start :name)) :to-equal "(setUpAll)")))

  (it "does not attribute the setUpAll print to real tests in the group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from setUpAll" "first test after setUpAll")
            :to-be nil)
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from setUpAll" "second test after setUpAll")
            :to-be nil))

  (it "attributes print in tearDownAll to the synthetic (tearDownAll) test"
    (let* ((log (verdict-dart-test--find-log verdict-dart-test--main-events "log from tearDownAll"))
           (log-id (plist-get log :id))
           (start (seq-find (lambda (ev)
                              (and (eq (plist-get ev :type) :test-start)
                                   (equal (plist-get ev :id) log-id)))
                            verdict-dart-test--main-events)))
      (expect start :not :to-be nil)
      (expect (or (plist-get start :label) (plist-get start :name)) :to-equal "(tearDownAll)")))

  (it "does not attribute the tearDownAll print to real tests in the group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from tearDownAll" "first test before tearDownAll")
            :to-be nil)
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from tearDownAll" "last test before tearDownAll")
            :to-be nil))

  (it "attributes print in tearDown to each test individually"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from tearDown" "a test with tearDown log")
            :to-be t)))

;;; fails_to_load.dart

(defvar verdict-dart-test--load-events nil
  "Cached verdict events from running fails_to_load.dart.")

(describe "verdict-dart: fails_to_load.dart"
  (before-each
    (unless verdict-dart-test--load-events
      (setq verdict-dart-test--load-events
            (verdict-dart-test--collect "fails_to_load"))))

  (it "emits a :group event for the test file"
    (expect (verdict-dart-test--find-group verdict-dart-test--load-events "fails_to_load.dart")
            :not :to-be nil))

  (it "emits an error :log attributed to the file group"
    (let ((logs (verdict-dart-test--logs-for-group verdict-dart-test--load-events
                                                   "fails_to_load.dart")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'error)))

  (it "emits a :test-done with error result for the suite"
    (let* ((file-group (verdict-dart-test--find-group verdict-dart-test--load-events
                                                      "fails_to_load.dart"))
           (suite-id   (plist-get file-group :id))
           (done-ev    (seq-find (lambda (ev)
                                   (and (eq (plist-get ev :type) :test-done)
                                        (equal (plist-get ev :id) suite-id)))
                                 verdict-dart-test--load-events)))
      (expect done-ev :not :to-be nil)
      (expect (plist-get done-ev :result) :to-be 'error)))

  (it "emits a :done event"
    (expect (verdict-dart-test--by-type verdict-dart-test--load-events :done)
            :not :to-be nil)))

;;; fails_during_setup.dart

(defvar verdict-dart-test--setup-events nil
  "Cached verdict events from running fails_during_setup.dart.")

(describe "verdict-dart: fails_during_setup.dart"
  (before-each
    (unless verdict-dart-test--setup-events
      (setq verdict-dart-test--setup-events
            (verdict-dart-test--collect "fails_during_setup"))))

  (it "emits a :test-start for 'a test'"
    (expect (verdict-dart-test--find-start verdict-dart-test--setup-events "a test")
            :not :to-be nil))

  (it "fails the test when setUp throws"
    (expect (verdict-dart-test--result verdict-dart-test--setup-events "a test")
            :to-be 'failed))

  (it "emits an error :log for the failed test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--setup-events "a test")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'error)))

  (it "emits a :done event"
    (expect (verdict-dart-test--by-type verdict-dart-test--setup-events :done)
            :not :to-be nil)))

;;; fails_during_teardown.dart

(defvar verdict-dart-test--teardown-events nil
  "Cached verdict events from running fails_during_teardown.dart.")

(describe "verdict-dart: fails_during_teardown.dart"
  (before-each
    (unless verdict-dart-test--teardown-events
      (setq verdict-dart-test--teardown-events
            (verdict-dart-test--collect "fails_during_teardown"))))

  (it "emits a :test-start for 'a test'"
    (expect (verdict-dart-test--find-start verdict-dart-test--teardown-events "a test")
            :not :to-be nil))

  (it "fails the test when tearDown throws"
    (expect (verdict-dart-test--result verdict-dart-test--teardown-events "a test")
            :to-be 'failed))

  (it "emits an error :log attributed to the test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--teardown-events "a test")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'error)))

  (it "emits a :done event"
    (expect (verdict-dart-test--by-type verdict-dart-test--teardown-events :done)
            :not :to-be nil)))

;;; fails_during_teardown_all.dart

(defvar verdict-dart-test--teardown-all-events nil
  "Cached verdict events from running fails_during_teardown_all.dart.")

(describe "verdict-dart: fails_during_teardown_all.dart"
  (before-each
    (unless verdict-dart-test--teardown-all-events
      (setq verdict-dart-test--teardown-all-events
            (verdict-dart-test--collect "fails_during_teardown_all"))))

  (it "emits a :test-start for 'a test'"
    (expect (verdict-dart-test--find-start verdict-dart-test--teardown-all-events "a test")
            :not :to-be nil))

  (it "passes 'a test' itself (tearDownAll is a separate synthetic test)"
    (expect (verdict-dart-test--result verdict-dart-test--teardown-all-events "a test")
            :to-be 'passed))

  (it "emits an error :log attributed to the synthetic (tearDownAll) test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--teardown-all-events "(tearDownAll)")))
      (expect logs :not :to-be nil)
      (expect (plist-get (car logs) :severity) :to-be 'error)))

  (it "emits a :done event"
    (expect (verdict-dart-test--by-type verdict-dart-test--teardown-all-events :done)
            :not :to-be nil)))

;;; fails_no_tests.dart

(describe "verdict-dart: fails_no_tests.dart"
  (it "emits no :test-start events"
    (let ((events (verdict-dart-test--collect "fails_no_tests")))
      (expect (verdict-dart-test--by-type events :test-start) :to-be nil)))

  (it "emits a :done event"
    (let ((events (verdict-dart-test--collect "fails_no_tests")))
      (expect (verdict-dart-test--by-type events :done) :not :to-be nil))))

;;; verdict-dart--pcre-quote

(describe "verdict-dart--pcre-quote"
  (it "passes plain text through unchanged"
    (expect (verdict-dart--pcre-quote "hello world")
            :to-equal "hello world"))

  (it "escapes the standard PCRE metacharacters"
    (expect (verdict-dart--pcre-quote "a.b|c?d*e+f(g)h[i]j{k}")
            :to-equal "a\\.b\\|c\\?d\\*e\\+f\\(g\\)h\\[i\\]j\\{k\\}"))

  (it "escapes anchors and pipe"
    (expect (verdict-dart--pcre-quote "^foo$")
            :to-equal "\\^foo\\$"))

  (it "escapes backslash"
    (expect (verdict-dart--pcre-quote "a\\b")
            :to-equal "a\\\\b")))

;;; verdict-dart--name-filter-args

(describe "verdict-dart--name-filter-args"
  (it "returns nil for no names"
    (expect (verdict-dart--name-filter-args nil) :to-be nil))

  (it "uses --plain-name for a single name"
    (expect (verdict-dart--name-filter-args '("my test"))
            :to-equal '("--plain-name" "my test")))

  (it "uses --name with anchored alternation for multiple names"
    (expect (verdict-dart--name-filter-args '("a" "b"))
            :to-equal '("--name" "^(a|b)$")))

  (it "escapes PCRE metacharacters in alternation"
    (expect (verdict-dart--name-filter-args '("a.b" "c|d"))
            :to-equal '("--name" "^(a\\.b|c\\|d)$"))))

;;; verdict-dart--linkify

(describe "verdict-dart--linkify"
  (it "returns the message unchanged when anchor-file is nil"
    (let ((msg "package:foo/bar.dart 10:5"))
      (expect (verdict-dart--linkify msg nil) :to-equal msg)))

  (it "marks a package: stack frame as a button"
    (let* ((msg    (verdict-dart--linkify "package:foo/bar.dart 10:5" "/proj/test/x.dart"))
           (action (get-text-property 0 'action msg)))
      (expect action :to-be-truthy)
      (expect (get-text-property 0 'category msg) :to-be 'default-button)
      (expect (get-text-property 0 'face msg)     :to-be 'link)))

  (it "marks a relative .dart path as a button"
    (let ((msg (verdict-dart--linkify "test/x.dart 7:1\nmore stuff" "/proj/test/x.dart")))
      (expect (get-text-property 0 'category msg) :to-be 'default-button)))

  (it "marks org-dartlang-sdk: paths as buttons"
    (let ((msg (verdict-dart--linkify "org-dartlang-sdk:///lib/core/foo.dart 1:2" "/proj/test/x.dart")))
      (expect (get-text-property 0 'category msg) :to-be 'default-button)))

  (it "leaves unrelated text unannotated"
    (let ((msg (verdict-dart--linkify "just a message" "/proj/test/x.dart")))
      (expect (get-text-property 0 'category msg) :to-be nil)))

  (it "annotates multiple frames in a stack trace"
    (let* ((trace "package:foo/a.dart 1:1\npackage:foo/b.dart 2:2")
           (msg   (verdict-dart--linkify trace "/proj/test/x.dart"))
           (n     (next-property-change 0 msg)))
      (expect (get-text-property 0 'category msg) :to-be 'default-button)
      (expect (get-text-property (1+ n) 'category msg) :to-be 'default-button))))

;;; verdict-dart--resolve-stack-path

(describe "verdict-dart--resolve-stack-path"
  (it "returns nil for dart: built-in URIs"
    (let ((default-directory temporary-file-directory))
      (expect (verdict-dart--resolve-stack-path "dart:core" temporary-file-directory)
              :to-be nil)))

  (it "resolves a relative path against the project root"
    (let* ((proj (make-temp-file "verdict-dart-test-" t))
           (verdict-dart--package-config nil))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "pubspec.yaml" proj) (insert "name: test\n"))
            (let* ((sub (expand-file-name "test" proj))
                   (resolved (progn (make-directory sub t)
                                    (verdict-dart--resolve-stack-path "lib/foo.dart" sub))))
              (expect resolved :to-equal (expand-file-name "lib/foo.dart" proj))))
        (delete-directory proj t))))

  (it "resolves package: URIs via the package config"
    (let* ((proj (make-temp-file "verdict-dart-test-" t))
           (lib  (expand-file-name "lib" proj))
           (verdict-dart--package-config nil))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "pubspec.yaml" proj) (insert "name: foo\n"))
            (make-directory lib t)
            (make-directory (expand-file-name ".dart_tool" proj) t)
            (with-temp-file (expand-file-name ".dart_tool/package_config.json" proj)
              (insert (format "{\"packages\":[{\"name\":\"foo\",\"rootUri\":\"file://%s\",\"packageUri\":\"lib/\"}]}"
                              proj)))
            (let ((resolved (verdict-dart--resolve-stack-path "package:foo/bar.dart" proj)))
              (expect resolved :to-equal (expand-file-name "bar.dart" lib))))
        (delete-directory proj t)))))

;;; verdict-dart--load-package-config

(describe "verdict-dart--load-package-config"
  (it "leaves the cache nil when no package_config.json exists"
    (let* ((proj (make-temp-file "verdict-dart-test-" t))
           (verdict-dart--package-config 'unset))
      (unwind-protect
          (progn
            (verdict-dart--load-package-config proj)
            (expect verdict-dart--package-config :to-be nil))
        (delete-directory proj t))))

  (it "parses package_config.json and resolves rootUri/packageUri"
    (let* ((proj (make-temp-file "verdict-dart-test-" t))
           (verdict-dart--package-config nil))
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".dart_tool" proj) t)
            (with-temp-file (expand-file-name ".dart_tool/package_config.json" proj)
              (insert (format "{\"packages\":[{\"name\":\"foo\",\"rootUri\":\"file://%s\",\"packageUri\":\"lib/\"}]}"
                              proj)))
            (verdict-dart--load-package-config proj)
            (expect (cdr (assoc "foo" verdict-dart--package-config))
                    :to-equal (file-name-as-directory (expand-file-name "lib" proj))))
        (delete-directory proj t)))))

;;; verdict-dart--flutter-project-p

(describe "verdict-dart--flutter-project-p"
  (it "is non-nil when pubspec depends on the flutter SDK"
    (let ((proj (make-temp-file "verdict-dart-test-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "pubspec.yaml" proj)
              (insert "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n"))
            (expect (verdict-dart--flutter-project-p proj) :to-be-truthy))
        (delete-directory proj t))))

  (it "is non-nil when a configured package is a dev_dependency"
    (let ((proj (make-temp-file "verdict-dart-test-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "pubspec.yaml" proj)
              (insert "name: app\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n"))
            (expect (verdict-dart--flutter-project-p proj) :to-be-truthy))
        (delete-directory proj t))))

  (it "is nil for a plain dart project"
    (let ((proj (make-temp-file "verdict-dart-test-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "pubspec.yaml" proj)
              (insert "name: app\ndependencies:\n  test: ^1.0.0\n"))
            (expect (verdict-dart--flutter-project-p proj) :to-be nil))
        (delete-directory proj t)))))

;;; verdict-dart--command-fn

(describe "verdict-dart--command-fn"
  (it "builds a dart test command for a non-flutter project"
    (spy-on 'verdict-dart--use-flutter-p :and-return-value nil)
    (let* ((ctx  '(:project "/p" :files ("/p/test/x.dart") :names nil :name "x"))
           (spec (verdict-dart--command-fn ctx nil)))
      (expect (plist-get spec :command)   :to-equal '("dart" "test" "-r" "json" "/p/test/x.dart"))
      (expect (plist-get spec :directory) :to-equal "/p")
      (expect (plist-get spec :name)      :to-equal "x")))

  (it "uses the flutter runner for a flutter project"
    (spy-on 'verdict-dart--use-flutter-p :and-return-value t)
    (let* ((ctx  '(:project "/p" :files ("/p/test/x.dart") :names nil :name "x"))
           (spec (verdict-dart--command-fn ctx nil)))
      (expect (car (plist-get spec :command)) :to-equal "flutter")))

  (it "passes --plain-name when one name is supplied"
    (spy-on 'verdict-dart--use-flutter-p :and-return-value nil)
    (let* ((ctx  '(:project "/p" :files ("/p/test/x.dart") :names ("my test") :name "my test"))
           (cmd  (plist-get (verdict-dart--command-fn ctx nil) :command)))
      (expect (member "--plain-name" cmd) :to-be-truthy)
      (expect (member "my test"      cmd) :to-be-truthy)))

  (it "returns a thunk command in debug mode"
    (spy-on 'verdict-dart--use-flutter-p :and-return-value nil)
    (let* ((ctx  '(:project "/p" :files ("/p/test/x.dart") :names nil :name "x"))
           (spec (verdict-dart--command-fn ctx t)))
      (expect (functionp (plist-get spec :command)) :to-be-truthy))))

(provide 'verdict-dart-test)
;;; verdict-dart-test.el ends here
