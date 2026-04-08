;;; verdict-demo.el --- Simulated test run for verdict -*- lexical-binding: t -*-

(require 'verdict)

(defun verdict-demo ()
  "Simulate a dart test run by feeding timed events to verdict."
  (interactive)
  (setq verdict--run-header "$ dart test -r json\n  in /my/project")
  (verdict-start)
  (let ((events
         ;; Each entry is (delay-seconds . event-plist)
         ;; Phases:
         ;;   0.0s — suites announced (all show spinner with no children)
         ;;   1.5s — groups appear (suites transition; groups spin waiting for tests)
         ;;   3.0s — tests start (groups transition; tests spin while running)
         ;;   4.0s+ — tests complete staggered
         `(;; Phase 1: suites only — all suite nodes spin
           (0.0  . (:type :group :id 1 :name "auth_test.dart"   :file "/my/project/test/auth_test.dart"   :parent-id nil))
           (0.0  . (:type :group :id 2 :name "cart_test.dart"   :file "/my/project/test/cart_test.dart"   :parent-id nil))
           (0.0  . (:type :group :id 3 :name "widget_test.dart" :file "/my/project/test/widget_test.dart" :parent-id nil))
           (0.0  . (:type :group :id 4 :name "broken_test.dart" :file "/my/project/test/broken_test.dart" :parent-id nil))
           ;; broken_test2.dart: announced but never receives any events — spins until stopped
           (0.0  . (:type :group :id 5 :name "broken_test2.dart" :file "/my/project/test/broken_test2.dart" :parent-id nil))

           ;; broken_test.dart fails immediately — file node goes straight to error
           (1.0  . (:type :log :id 4 :severity error
                          :message "Error: Compilation failed.\ntest/broken_test.dart:5:3: Error: Undefined name 'undefinedVar'.\n  undefinedVar;\n  ^^^^^^^^^^^"))
           (1.0  . (:type :test-done :id 4 :result error))

           ;; Phase 2: groups appear one by one — group nodes spin waiting for tests
           (1.5  . (:type :group :id 10 :parent-id 1  :name "AuthService"  :line 5))
           (2.0  . (:type :group :id 20 :parent-id 2  :name "Cart"         :line 3))
           (2.5  . (:type :group :id 21 :parent-id 20 :name "Cart addItem" :line 7))
           (2.5  . (:type :group :id 30 :parent-id 3  :name "LoginWidget"  :line 4))

           ;; Phase 3: tests start — individual test nodes spin while running
           (3.0  . (:type :test-start :id 100 :parent-id 10 :name "login succeeds"           :line 8))
           (3.0  . (:type :test-start :id 101 :parent-id 10 :name "login wrong password"     :line 15))
           (3.0  . (:type :test-start :id 102 :parent-id 10 :name "logout clears token"      :line 22))
           (3.0  . (:type :test-start :id 200 :parent-id 21 :name "increases quantity"        :line 9))
           (3.0  . (:type :test-start :id 201 :parent-id 21 :name "updates total"             :line 16))
           (3.0  . (:type :test-start :id 202 :parent-id 20 :name "handles concurrent modifications" :line 24))
           (3.0  . (:type :test-start :id 300 :parent-id 30 :name "renders email field"      :line 7))
           (3.0  . (:type :test-start :id 301 :parent-id 30 :name "shows error on empty submit" :line 18))
           (3.0  . (:type :test-start :id 302 :parent-id 30 :name "animation completes"      :line 30))

           ;; Phase 4: print output and completions, staggered
           (3.5  . (:type :log :severity info :id 100 :message "Sending POST /auth/login"))
           (4.0  . (:type :log :severity info :id 100 :message "Response: 200 OK, token received"))
           (4.5  . (:type :test-done :id 100 :result passed :hidden nil :skipped nil))
           (5.0  . (:type :log :severity info :id 200 :message "Cart was empty, adding first item"))
           (5.5  . (:type :test-done :id 300 :result passed :hidden nil :skipped nil))
           (6.0  . (:type :test-done :id 200 :result passed :hidden nil :skipped nil))
           (6.5  . (:type :log :severity info :id 102 :message "Logout called, clearing token"))
           (7.0  . (:type :test-done :id 102 :result passed :hidden nil :skipped nil))
           (7.5  . (:type :test-done :id 101 :result passed :hidden nil :skipped nil))
           (8.0  . (:type :test-done :id 201 :result passed :hidden nil :skipped nil))
           (8.5  . (:type :test-done :id 202 :result passed :hidden t   :skipped t))
           (8.5  . (:type :log :severity info :id 301 :message "Submitting form with empty fields"))
           (9.0  . (:type :log :id 301 :severity error
                          :message "Expected: <true>\n  Actual: <false>\npackage:test  expect\ntest/widget_test.dart 22:5  main.<fn>.<fn>"))
           (9.0  . (:type :test-done :id 301 :result failed :hidden nil :skipped nil))

           ;; 302 is still running when the process finishes
           (9.5  . (:type :done :success nil)))))
    (dolist (entry events)
      (let ((delay (car entry))
            (event (cdr entry)))
        (run-with-timer delay nil #'verdict-event event)))
    (run-with-timer 10.0 nil #'verdict-stop)))

(provide 'verdict-demo)
;;; verdict-demo.el ends here
