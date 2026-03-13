;;; verdict-test.el --- Buttercup tests for verdict.el -*- lexical-binding: t -*-

(require 'buttercup)
(require 'verdict)

;;; Helpers

(defun verdict-test--reset ()
  "Reset all verdict global state for test isolation."
  (clrhash verdict--nodes)
  (setq verdict--root-ids   nil
        verdict--render-timer nil
        verdict--spinner-timer nil
        verdict--spinner-frame 0
        verdict--partial      ""
        verdict--proc         nil
        verdict--last-command nil
        verdict--backend      nil
        verdict-model         nil))

(defun verdict-test--node (id &rest props)
  "Store a node with ID and PROPS in verdict--nodes and return it."
  (let ((node (append (list :id id) props)))
    (puthash id node verdict--nodes)
    node))

;;; verdict--render-message

(describe "verdict--render-message"
  (it "returns a plain string for info severity"
    (let ((result (verdict--render-message 'info "hello")))
      (expect result :to-equal "hello")
      (expect (get-text-property 0 'face result) :to-be nil)))

  (it "propertizes error messages with verdict-error-face"
    (let ((result (verdict--render-message 'error "boom")))
      (expect (substring-no-properties result) :to-equal "boom")
      (expect (get-text-property 0 'face result) :to-be 'verdict-error-face)))

  (it "returns a plain string for nil severity"
    (let ((result (verdict--render-message nil "msg")))
      (expect result :to-equal "msg"))))

;;; verdict--output-node

(describe "verdict--output-node"
  (it "generates a synthetic id from the parent id"
    (expect (plist-get (verdict--output-node "g1" "Label" "out") :id)
            :to-equal "output-g1"))

  (it "stores the output string"
    (expect (plist-get (verdict--output-node "g" "L" "the output") :output)
            :to-equal "the output"))

  (it "uses the parent label as :title"
    (expect (plist-get (verdict--output-node "g" "My Label" "out") :title)
            :to-equal "My Label"))

  (it "has nil :status"
    (expect (plist-get (verdict--output-node "g" "L" "out") :status)
            :to-be nil))

  (it "has a propertized <init> :label"
    (let* ((node  (verdict--output-node "g" "L" "out"))
           (label (plist-get node :label)))
      (expect (substring-no-properties label) :to-equal "<init>")
      (expect (get-text-property 0 'face label) :to-be 'verdict-init-face))))

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

;;; verdict-register-backend

(describe "verdict-register-backend"
  (before-each (verdict-test--reset))

  (it "stores :command-fn"
    (let ((cmd-fn (lambda (_) nil)))
      (verdict-register-backend cmd-fn (lambda (_) nil))
      (expect (plist-get verdict--backend :command-fn) :to-be cmd-fn)))

  (it "stores :line-handler"
    (let ((handler (lambda (_) nil)))
      (verdict-register-backend (lambda (_) nil) handler)
      (expect (plist-get verdict--backend :line-handler) :to-be handler)))

  (it "replaces a previously registered backend"
    (verdict-register-backend (lambda (_) 'old) (lambda (_) nil))
    (let ((new-fn (lambda (_) 'new)))
      (verdict-register-backend new-fn (lambda (_) nil))
      (expect (plist-get verdict--backend :command-fn) :to-be new-fn))))

;;; verdict-reset

(describe "verdict-reset"
  (before-each (verdict-test--reset))

  (it "clears verdict--nodes"
    (puthash "x" '(:id "x") verdict--nodes)
    (verdict-reset)
    (expect (hash-table-count verdict--nodes) :to-be 0))

  (it "clears verdict--root-ids"
    (setq verdict--root-ids '("a" "b"))
    (verdict-reset)
    (expect verdict--root-ids :to-be nil))

  (it "clears verdict-model"
    (setq verdict-model '((:id "x")))
    (verdict-reset)
    (expect verdict-model :to-be nil))

  (it "cancels a pending render timer"
    (spy-on 'cancel-timer)
    (setq verdict--render-timer 'fake-timer)
    (verdict-reset)
    (expect 'cancel-timer :to-have-been-called)
    (expect verdict--render-timer :to-be nil))

  (it "does not cancel when no render timer is pending"
    (spy-on 'cancel-timer)
    (setq verdict--render-timer nil)
    (verdict-reset)
    (expect 'cancel-timer :not :to-have-been-called))

  (it "stops the spinner"
    (spy-on 'verdict--spinner-stop)
    (verdict-reset)
    (expect 'verdict--spinner-stop :to-have-been-called)))

;;; verdict--add-child

(describe "verdict--add-child"
  (before-each (verdict-test--reset))

  (it "adds a child to an empty :children list"
    (verdict-test--node "parent" :children nil)
    (verdict--add-child "parent" "c1")
    (expect (plist-get (gethash "parent" verdict--nodes) :children)
            :to-equal '("c1")))

  (it "appends to existing children"
    (verdict-test--node "parent" :children '("c1"))
    (verdict--add-child "parent" "c2")
    (expect (plist-get (gethash "parent" verdict--nodes) :children)
            :to-equal '("c1" "c2")))

  (it "preserves insertion order across multiple appends"
    (verdict-test--node "p" :children nil)
    (verdict--add-child "p" "a")
    (verdict--add-child "p" "b")
    (verdict--add-child "p" "c")
    (expect (plist-get (gethash "p" verdict--nodes) :children)
            :to-equal '("a" "b" "c"))))

;;; verdict-event

(describe "verdict-event"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict--schedule-render))

  (describe ":group"
    (it "creates a node in verdict--nodes"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 1 :parent-id nil))
      (expect (gethash "g1" verdict--nodes) :not :to-be nil))

    (it "stores :label, :file, and :line on the node"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 5 :parent-id nil))
      (let ((node (gethash "g1" verdict--nodes)))
        (expect (plist-get node :label) :to-equal "Suite")
        (expect (plist-get node :file)  :to-equal "/a.dart")
        (expect (plist-get node :line)  :to-be 5)))

    (it "initialises :status to running"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 1 :parent-id nil))
      (expect (plist-get (gethash "g1" verdict--nodes) :status) :to-be 'running))

    (it "initialises :children to nil (not absent)"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 1 :parent-id nil))
      (let ((node (gethash "g1" verdict--nodes)))
        (expect (plist-member node :children) :not :to-be nil)
        (expect (plist-get node :children) :to-be nil)))

    (it "adds to root-ids when parent-id is nil"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 1 :parent-id nil))
      (expect verdict--root-ids :to-equal '("g1")))

    (it "adds to root-ids when parent-id is not found in verdict--nodes"
      (verdict-event '(:type :group :id "g1" :name "Suite" :file "/a.dart" :line 1 :parent-id "nonexistent"))
      (expect verdict--root-ids :to-equal '("g1")))

    (it "adds as child of an existing parent and does not touch root-ids"
      (verdict-test--node "parent" :children nil)
      (verdict-event '(:type :group :id "child" :name "Child" :file "/a.dart" :line 2 :parent-id "parent"))
      (expect verdict--root-ids :to-be nil)
      (expect (plist-get (gethash "parent" verdict--nodes) :children) :to-equal '("child")))

    (it "preserves order of multiple root groups"
      (verdict-event '(:type :group :id "g1" :name "A" :file "/a.dart" :line 1 :parent-id nil))
      (verdict-event '(:type :group :id "g2" :name "B" :file "/b.dart" :line 1 :parent-id nil))
      (verdict-event '(:type :group :id "g3" :name "C" :file "/c.dart" :line 1 :parent-id nil))
      (expect verdict--root-ids :to-equal '("g1" "g2" "g3")))

    (it "schedules a render"
      (verdict-event '(:type :group :id "g1" :name "X" :file "/a.dart" :line 1 :parent-id nil))
      (expect 'verdict--schedule-render :to-have-been-called)))

  (describe ":test-start"
    (it "creates a node with running status"
      (verdict-test--node "parent" :children nil)
      (verdict-event '(:type :test-start :id "t1" :name "test it" :parent-id "parent" :file "/a.dart" :line 10))
      (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'running))

    (it "stores :label, :file, and :line"
      (verdict-test--node "parent" :children nil)
      (verdict-event '(:type :test-start :id "t1" :name "my test" :parent-id "parent" :file "/f.dart" :line 7))
      (let ((node (gethash "t1" verdict--nodes)))
        (expect (plist-get node :label) :to-equal "my test")
        (expect (plist-get node :file)  :to-equal "/f.dart")
        (expect (plist-get node :line)  :to-be 7)))

    (it "adds the test as a child of its parent"
      (verdict-test--node "parent" :children nil)
      (verdict-event '(:type :test-start :id "t1" :name "t" :parent-id "parent" :file "/a.dart" :line 1))
      (expect (plist-get (gethash "parent" verdict--nodes) :children) :to-equal '("t1")))

    (it "schedules a render"
      (verdict-test--node "parent" :children nil)
      (verdict-event '(:type :test-start :id "t1" :name "t" :parent-id "parent" :file "/a.dart" :line 1))
      (expect 'verdict--schedule-render :to-have-been-called)))

  (describe ":log"
    (it "sets :output on the node for the first message"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :log :id "t1" :severity info :message "first line"))
      (expect (plist-get (gethash "t1" verdict--nodes) :output) :to-equal "first line"))

    (it "appends subsequent messages with a newline separator"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :log :id "t1" :severity info :message "line 1"))
      (verdict-event '(:type :log :id "t1" :severity info :message "line 2"))
      (expect (plist-get (gethash "t1" verdict--nodes) :output) :to-equal "line 1\nline 2"))

    (it "propertizes error messages with verdict-error-face"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :log :id "t1" :severity error :message "oh no"))
      (let ((output (plist-get (gethash "t1" verdict--nodes) :output)))
        (expect (get-text-property 0 'face output) :to-be 'verdict-error-face)))

    (it "does not propertize info messages"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :log :id "t1" :severity info :message "plain"))
      (let ((output (plist-get (gethash "t1" verdict--nodes) :output)))
        (expect (get-text-property 0 'face output) :to-be nil)))

    (it "ignores events for unknown node ids"
      (verdict-event '(:type :log :id "unknown" :severity info :message "msg"))
      (expect (gethash "unknown" verdict--nodes) :to-be nil))

    (it "schedules a render"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :log :id "t1" :severity info :message "msg"))
      (expect 'verdict--schedule-render :to-have-been-called)))

  (describe ":test-done"
    (it "updates the node's :status to the result"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :test-done :id "t1" :result passed))
      (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'passed))

    (it "can mark a test as failed"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :test-done :id "t1" :result failed))
      (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'failed))

    (it "can mark a test as skipped"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :test-done :id "t1" :result skipped))
      (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'skipped))

    (it "ignores unknown ids silently"
      (expect (verdict-event '(:type :test-done :id "ghost" :result passed))
              :not :to-throw))

    (it "schedules a render"
      (verdict-test--node "t1" :status 'running)
      (verdict-event '(:type :test-done :id "t1" :result passed))
      (expect 'verdict--schedule-render :to-have-been-called)))

  (describe ":done"
    (it "schedules a render"
      (verdict-event '(:type :done))
      (expect 'verdict--schedule-render :to-have-been-called))))

;;; verdict--build-tree

(describe "verdict--build-tree"
  (before-each (verdict-test--reset))

  (it "returns an empty list for empty ids"
    (expect (verdict--build-tree '()) :to-equal '()))

  (it "returns leaf nodes as-is"
    (verdict-test--node "t1" :label "test" :status 'passed :file "/f.dart" :line 1)
    (let ((tree (verdict--build-tree '("t1"))))
      (expect (length tree) :to-be 1)
      (expect (plist-get (car tree) :label) :to-equal "test")
      (expect (plist-get (car tree) :status) :to-be 'passed)))

  (it "resolves child ids into nested plists"
    (verdict-test--node "g1" :label "Group" :children '("t1"))
    (verdict-test--node "t1" :label "Test"  :status 'passed)
    (let* ((tree  (verdict--build-tree '("g1")))
           (child (car (plist-get (car tree) :children))))
      (expect (plist-get child :label) :to-equal "Test")))

  (it "resolves children recursively"
    (verdict-test--node "g1" :label "Top"  :children '("g2"))
    (verdict-test--node "g2" :label "Mid"  :children '("t1"))
    (verdict-test--node "t1" :label "Leaf" :status 'passed)
    (let* ((tree (verdict--build-tree '("g1")))
           (mid  (car (plist-get (car tree) :children)))
           (leaf (car (plist-get mid :children))))
      (expect (plist-get leaf :label) :to-equal "Leaf")))

  (it "aggregates child statuses for group nodes"
    (verdict-test--node "g1" :label "Group" :children '("t1" "t2"))
    (verdict-test--node "t1" :label "A" :status 'passed)
    (verdict-test--node "t2" :label "B" :status 'failed)
    (expect (plist-get (car (verdict--build-tree '("g1"))) :status) :to-be 'failed))

  (it "injects a synthetic output node as first child when group has output"
    (verdict-test--node "g1" :label "Group" :children '("t1") :output "compile error")
    (verdict-test--node "t1" :label "Test"  :status 'passed)
    (let* ((children (plist-get (car (verdict--build-tree '("g1"))) :children)))
      (expect (plist-get (car children) :id) :to-equal "output-g1")))

  (it "places the synthetic output node before real children"
    (verdict-test--node "g1" :label "Group" :children '("t1") :output "err")
    (verdict-test--node "t1" :label "Test"  :status 'passed)
    (let* ((children (plist-get (car (verdict--build-tree '("g1"))) :children)))
      (expect (length children) :to-be 2)
      (expect (plist-get (cadr children) :id) :to-equal "t1")))

  (it "injects an output node as sole child when :children is nil but output exists"
    (verdict-test--node "g1" :label "Group" :children nil :output "fail" :status 'error)
    (let* ((children (plist-get (car (verdict--build-tree '("g1"))) :children)))
      (expect (length children) :to-be 1)
      (expect (plist-get (car children) :id) :to-equal "output-g1")))

  (it "does not inject an output node when the group has no output"
    (verdict-test--node "g1" :label "Group" :children '("t1"))
    (verdict-test--node "t1" :label "Test"  :status 'passed)
    (let* ((children (plist-get (car (verdict--build-tree '("g1"))) :children)))
      (expect (length children) :to-be 1)
      (expect (plist-get (car children) :id) :to-equal "t1")))

  (it "preserves order of multiple root nodes"
    (verdict-test--node "a" :label "A" :status 'passed)
    (verdict-test--node "b" :label "B" :status 'failed)
    (verdict-test--node "c" :label "C" :status 'skipped)
    (expect (mapcar (lambda (n) (plist-get n :label))
                    (verdict--build-tree '("a" "b" "c")))
            :to-equal '("A" "B" "C"))))

;;; verdict-stop

(describe "verdict-stop"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict--render))

  (it "marks running nodes as stopped"
    (verdict-test--node "t1" :status 'running)
    (verdict-stop)
    (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'stopped))

  (it "leaves non-running nodes unchanged"
    (verdict-test--node "t1" :status 'passed)
    (verdict-test--node "t2" :status 'failed)
    (verdict-stop)
    (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'passed)
    (expect (plist-get (gethash "t2" verdict--nodes) :status) :to-be 'failed))

  (it "stops only running nodes when mixed"
    (verdict-test--node "t1" :status 'running)
    (verdict-test--node "t2" :status 'passed)
    (verdict-test--node "t3" :status 'running)
    (verdict-stop)
    (expect (plist-get (gethash "t1" verdict--nodes) :status) :to-be 'stopped)
    (expect (plist-get (gethash "t2" verdict--nodes) :status) :to-be 'passed)
    (expect (plist-get (gethash "t3" verdict--nodes) :status) :to-be 'stopped))

  (it "stops the spinner"
    (spy-on 'verdict--spinner-stop)
    (verdict-stop)
    (expect 'verdict--spinner-stop :to-have-been-called))

  (it "cancels a pending render timer"
    (spy-on 'cancel-timer)
    (setq verdict--render-timer 'fake-timer)
    (verdict-stop)
    (expect verdict--render-timer :to-be nil))

  (it "calls verdict--render"
    (verdict-stop)
    (expect 'verdict--render :to-have-been-called)))

;;; verdict--filter

(describe "verdict--filter"
  (before-each
    (verdict-test--reset))

  (it "calls the handler for a single complete line"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (verdict--filter nil "hello\n")
      (expect received :to-equal '("hello"))))

  (it "buffers a partial line without calling the handler"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (verdict--filter nil "partial")
      (expect received :to-be nil)
      (expect verdict--partial :to-equal "partial")))

  (it "combines a buffered partial with the next chunk to form a complete line"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (verdict--filter nil "hel")
      (verdict--filter nil "lo\n")
      (expect received :to-equal '("hello"))))

  (it "handles multiple complete lines in one chunk"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (verdict--filter nil "line1\nline2\nline3\n")
      (expect (reverse received) :to-equal '("line1" "line2" "line3"))))

  (it "retains a trailing partial after processing complete lines"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (verdict--filter nil "a\nb\npartial")
      (expect (reverse received) :to-equal '("a" "b"))
      (expect verdict--partial :to-equal "partial")))

  (it "handles an empty chunk without errors"
    (verdict-register-backend (lambda (_) nil) (lambda (_) nil))
    (expect (verdict--filter nil "") :not :to-throw)))

;;; verdict--sentinel

(describe "verdict--sentinel"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict-stop))

  (it "flushes a non-empty partial buffer through the handler"
    (let ((received nil))
      (verdict-register-backend (lambda (_) nil) (lambda (line) (push line received)))
      (setq verdict--partial "leftover")
      (verdict--sentinel nil "finished\n")
      (expect received :to-equal '("leftover"))
      (expect verdict--partial :to-equal "")))

  (it "does not call the handler when partial is empty"
    (let ((call-count 0))
      (verdict-register-backend (lambda (_) nil) (lambda (_) (cl-incf call-count)))
      (setq verdict--partial "")
      (verdict--sentinel nil "finished\n")
      (expect call-count :to-be 0)))

  (it "calls verdict-stop when the proc matches verdict--proc"
    (let ((proc 'fake-proc))
      (setq verdict--proc proc)
      (verdict--sentinel proc "finished\n")
      (expect 'verdict-stop :to-have-been-called)))

  (it "does not call verdict-stop for a stale proc"
    (setq verdict--proc 'current-proc)
    (verdict--sentinel 'old-proc "finished\n")
    (expect 'verdict-stop :not :to-have-been-called)))

;;; Spinner

(describe "verdict--spinner-frames"
  (it "returns braille frames when spinner-style is braille"
    (let ((verdict-spinner-style 'braille))
      (expect (verdict--spinner-frames) :to-be verdict--spinner-frames-braille)))

  (it "returns ascii frames when spinner-style is ascii"
    (let ((verdict-spinner-style 'ascii))
      (expect (verdict--spinner-frames) :to-be verdict--spinner-frames-ascii))))

(describe "verdict--spinner-start"
  (before-each (verdict-test--reset))

  (it "resets the frame index to 0"
    (setq verdict--spinner-frame 5)
    (spy-on 'run-with-timer :and-return-value 'fake-timer)
    (verdict--spinner-start)
    (expect verdict--spinner-frame :to-be 0))

  (it "starts a repeating timer with the correct interval"
    (spy-on 'run-with-timer :and-return-value 'fake-timer)
    (verdict--spinner-start)
    (expect 'run-with-timer :to-have-been-called-with 0.15 0.15 #'verdict--spinner-tick))

  (it "stores the timer in verdict--spinner-timer"
    (spy-on 'run-with-timer :and-return-value 'fake-timer)
    (verdict--spinner-start)
    (expect verdict--spinner-timer :to-be 'fake-timer))

  (it "does not create a second timer if one is already running"
    (setq verdict--spinner-timer 'already-running)
    (spy-on 'run-with-timer)
    (verdict--spinner-start)
    (expect 'run-with-timer :not :to-have-been-called)))

(describe "verdict--spinner-stop"
  (before-each (verdict-test--reset))

  (it "cancels the timer"
    (spy-on 'cancel-timer)
    (setq verdict--spinner-timer 'fake-timer)
    (verdict--spinner-stop)
    (expect 'cancel-timer :to-have-been-called-with 'fake-timer))

  (it "sets verdict--spinner-timer to nil"
    (spy-on 'cancel-timer)
    (setq verdict--spinner-timer 'fake-timer)
    (verdict--spinner-stop)
    (expect verdict--spinner-timer :to-be nil))

  (it "does nothing when no timer is active"
    (spy-on 'cancel-timer)
    (setq verdict--spinner-timer nil)
    (verdict--spinner-stop)
    (expect 'cancel-timer :not :to-have-been-called)))

(describe "verdict--spinner-tick"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict--schedule-render))

  (it "advances the frame index by one"
    (setq verdict--spinner-frame 0)
    (verdict--spinner-tick)
    (expect verdict--spinner-frame :to-be 1))

  (it "wraps around at the end of the frame list"
    (let* ((frames     (verdict--spinner-frames))
           (last-frame (1- (length frames))))
      (setq verdict--spinner-frame last-frame)
      (verdict--spinner-tick)
      (expect verdict--spinner-frame :to-be 0)))

  (it "schedules a render"
    (verdict--spinner-tick)
    (expect 'verdict--schedule-render :to-have-been-called)))

;;; verdict--run / verdict-rerun

(describe "verdict--run"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict--launch))

  (it "signals an error when no backend is registered"
    (expect (verdict--run :project) :to-throw 'error))

  (it "calls command-fn with the given scope"
    (let ((received-scope nil)
          (spec '(:command ("echo") :directory "/tmp" :name "test")))
      (verdict-register-backend
       (lambda (scope) (setq received-scope scope) spec)
       (lambda (_) nil))
      (verdict--run :project)
      (expect received-scope :to-be :project)))

  (it "stores the command result in verdict--last-command"
    (let ((spec '(:command ("echo") :directory "/tmp" :name "test")))
      (verdict-register-backend (lambda (_) spec) (lambda (_) nil))
      (verdict--run :file)
      (expect verdict--last-command :to-equal spec)))

  (it "calls verdict--launch with the command spec"
    (let ((spec '(:command ("echo") :directory "/tmp" :name "test")))
      (verdict-register-backend (lambda (_) spec) (lambda (_) nil))
      (verdict--run :file)
      (expect 'verdict--launch :to-have-been-called-with spec))))

(describe "verdict-rerun"
  (before-each
    (verdict-test--reset)
    (spy-on 'verdict--launch))

  (it "signals an error when there is no previous run"
    (expect (verdict-rerun) :to-throw 'error))

  (it "calls verdict--launch with the stored command spec"
    (let ((spec '(:command ("dart" "test") :directory "/proj" :name "rerun")))
      (setq verdict--last-command spec)
      (verdict-rerun)
      (expect 'verdict--launch :to-have-been-called-with spec)))

  (it "does not call command-fn again"
    (let ((call-count 0)
          (spec '(:command ("echo") :directory "/tmp" :name "test")))
      (verdict-register-backend (lambda (_) (cl-incf call-count) spec) (lambda (_) nil))
      (setq verdict--last-command spec)
      (verdict-rerun)
      (expect call-count :to-be 0))))

;;; Output buffer (verdict--show-output)
;;
;; verdict--show-output cannot be unit-tested because treemacs-button-get is a
;; defsubst that the byte-compiler inlines into verdict--show-output at compile
;; time.  spy-on replaces the symbol's function cell, but the inlined call in
;; the compiled body bypasses it.  These are better covered by manual / demo
;; testing via verdict-demo.el.

(provide 'verdict-test)
;;; verdict-test.el ends here
