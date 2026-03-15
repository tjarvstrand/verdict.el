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
  "Return the :test-start event with :name NAME, or nil."
  (seq-find (lambda (ev)
              (and (eq (plist-get ev :type) :test-start)
                   (equal (plist-get ev :name) name)))
            events))

(defun verdict-dart-test--find-group (events name)
  "Return the :group event with :name NAME, or nil."
  (seq-find (lambda (ev)
              (and (eq (plist-get ev :type) :group)
                   (equal (plist-get ev :name) name)))
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
              :to-equal (expand-file-name "test/dart_test.dart" verdict-dart-test--dir))))

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

  (it "attributes print in setUpAll to the first test in that group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from setUpAll" "first test after setUpAll")
            :to-be t))

  (it "does not attribute the setUpAll print to later tests in the group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from setUpAll" "second test after setUpAll")
            :to-be nil))

  (it "attributes print in tearDownAll to the last test in that group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from tearDownAll" "last test before tearDownAll")
            :to-be t))

  (it "does not attribute the tearDownAll print to earlier tests in the group"
    (expect (verdict-dart-test--log-goes-to-test-p
             verdict-dart-test--main-events "log from tearDownAll" "first test before tearDownAll")
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

  (it "fails the test when tearDownAll throws"
    (expect (verdict-dart-test--result verdict-dart-test--teardown-all-events "a test")
            :to-be 'failed))

  (it "emits an error :log attributed to the test"
    (let ((logs (verdict-dart-test--logs-for-test verdict-dart-test--teardown-all-events "a test")))
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

(provide 'verdict-dart-test)
;;; verdict-dart-test.el ends here
