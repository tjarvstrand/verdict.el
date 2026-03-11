;;; verdict-test.el --- Buttercup tests for verdict.el -*- lexical-binding: t -*-

(require 'buttercup)
(require 'verdict)

;;; verdict--worst-status

(describe "verdict--worst-status"

  (it "returns nil for an empty list"
    (expect (verdict--worst-status '()) :to-be nil))

  (it "returns nil when all statuses are nil"
    (expect (verdict--worst-status '(nil nil nil)) :to-be nil))

  (it "returns the sole status"
    (expect (verdict--worst-status '(passed)) :to-be 'passed))

  (it "ignores nil values"
    (expect (verdict--worst-status '(nil passed nil)) :to-be 'passed))

  (it "returns error as highest severity"
    (expect (verdict--worst-status '(passed failed running skipped stopped error)) :to-be 'error))

  (it "returns failed over running"
    (expect (verdict--worst-status '(running failed)) :to-be 'failed))

  (it "returns running over passed"
    (expect (verdict--worst-status '(passed running)) :to-be 'running))

  (it "returns passed over skipped"
    (expect (verdict--worst-status '(skipped passed)) :to-be 'passed))

  (it "returns skipped over stopped"
    (expect (verdict--worst-status '(stopped skipped)) :to-be 'skipped))

  (it "returns stopped for a list containing only stopped"
    (expect (verdict--worst-status '(stopped)) :to-be 'stopped))

  (it "handles duplicate statuses"
    (expect (verdict--worst-status '(passed passed failed passed)) :to-be 'failed))

  (it "is not sensitive to list order"
    (let ((statuses '(skipped error passed running failed)))
      (expect (verdict--worst-status statuses) :to-be 'error)
      (expect (verdict--worst-status (reverse statuses)) :to-be 'error))))

(provide 'verdict-test)
;;; verdict-test.el ends here
