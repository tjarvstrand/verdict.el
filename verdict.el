;;; verdict.el --- Generic test runner with treemacs results UI -*- lexical-binding: t -*-
;;
;; Package-Requires: ((emacs "30.0") (treemacs "2.0") (dash "2.0") (s "1.0"))

(require 'treemacs-treelib)
(require 'ansi-color)
(require 'dash)
(require 's)

;; TODO
;; - Simplify code
;; - Tests
;; - Figure out actions for click, RET, etc.
;; - Inhibit same window then displaying buffer for the first time

;;; Faces

(defface verdict-success-face
  '((t :inherit success))
  "Face for passed tests.")

(defface verdict-error-face
  '((t :inherit error))
  "Face for failed or errored tests.")

(defface verdict-skipped-face
  '((t :inherit shadow))
  "Face for skipped tests.")

(defface verdict-running-face
  '((t :foreground "#8be9fd"))
  "Face for running tests.")

(defface verdict-stopped-face
  '((t :inherit shadow))
  "Face for stopped tests.")

(defface verdict-init-face
  '((t :inherit shadow))
  "Face for the synthetic <init> output node.")

(defface verdict-name-face
  '((t :inherit shadow))
  "Face for test name header in the output buffer.")

;;; Customization

(defcustom verdict-icon-height 1.4
  "Relative height of verdict status icons, as a float (1.0 = normal size)."
  :type 'number
  :group 'verdict)

(defcustom verdict-icon-open    "▾" "Icon for expanded group/file nodes."  :type 'string :group 'verdict)
(defcustom verdict-icon-closed  "▸" "Icon for collapsed group/file nodes." :type 'string :group 'verdict)
(defcustom verdict-icon-passed  "✓" "Icon for passed tests."               :type 'string :group 'verdict)
(defcustom verdict-icon-failed  "✗" "Icon for failed tests."               :type 'string :group 'verdict)
(defcustom verdict-icon-error   "!" "Icon for errored tests."              :type 'string :group 'verdict)
(defcustom verdict-icon-skipped "-" "Icon for skipped tests."              :type 'string :group 'verdict)
(defcustom verdict-icon-stopped "⊘" "Icon for stopped tests."             :type 'string :group 'verdict)

(defcustom verdict-save-before-run nil
  "How to handle unsaved changes in the current buffer before a test run.
`yes' — always save silently.
`no'  — never save.
nil   — prompt before each run, then offer to remember the answer."
  :type '(choice (const :tag "Always save"  yes)
                 (const :tag "Never save"   no)
                 (const :tag "Ask each run" nil))
  :group 'verdict)


;;; Global State

(defvar verdict--nodes nil
  "Alist-tree of test nodes at the root level: ((id . node) ...).")

(defvar verdict--paths (make-hash-table :test #'equal)
  "Hash table mapping node id to its path list into verdict--nodes.")

(defvar verdict--loading-tests (make-hash-table :test #'equal)
  "Hash table mapping loading-test id to its file-id.")

(defvar verdict--render-timer nil
  "Debounce timer for rendering.")

(defconst verdict--spinner-frames ["|" "/" "-" "\\"]
  "Animation frames for the running spinner.")

(defvar verdict--spinner-frame 0
  "Current frame index into `verdict--spinner-frames'.")

(defvar verdict--spinner-timer nil
  "Repeating timer that advances the spinner and schedules a render.")

(defvar verdict-model nil
  "List of root node plists (display model, derived from verdict--nodes).")

(defvar verdict-buffer-name "*verdict*"
  "Name of the verdict results buffer.")

(defvar verdict-log-events nil
  "Whether to print runner events to the messages buffer")

;;; Status Aggregation

(defconst verdict--status-severity
  '((error . 5) (failed . 4) (running . 3) (passed . 2) (skipped . 1) (stopped . 0))
  "Severity order for aggregating group status from children.")

(defun verdict--worst-status (statuses)
  "Return the highest-severity status from STATUSES list."
  (-max-by (-on #'> (lambda (status) (alist-get status verdict--status-severity 0))) statuses))

;;; Icon/Face Helpers

(defun verdict--status-face (status)
  "Return face symbol for STATUS."
  (pcase status
    ('passed  'verdict-success-face)
    ('failed  'verdict-error-face)
    ('error   'verdict-error-face)
    ('skipped 'verdict-skipped-face)
    ('running 'verdict-running-face)
    ('stopped 'verdict-stopped-face)
    (_        'default)))

(defun verdict--effective-status (status)
  "Return STATUS, treating nil as 'running when a run is active."
  (if (and (null status) verdict--spinner-timer) 'running status))

(defun verdict--leaf-icon (status)
  "Return 2-char propertized icon string for leaf node with STATUS."
  (let* ((status (verdict--effective-status status))
         (icon (pcase status
                 ('running (aref verdict--spinner-frames verdict--spinner-frame))
                 ('passed  verdict-icon-passed)
                 ('failed  verdict-icon-failed)
                 ('error   verdict-icon-error)
                 ('skipped verdict-icon-skipped)
                 ('stopped verdict-icon-stopped)
                 (_        " "))))
    (verdict--render-icon status icon)))

(defun verdict--group-icon (status open)
  "Return propertized group icon string for STATUS; OPEN controls arrow direction."
  (verdict--render-icon status (if open verdict-icon-open verdict-icon-closed)))

(defun verdict--render-icon (status icon-char)
  "Return propertized group icon string for ICON-CHAR."
  (let ((face (verdict--status-face (verdict--effective-status status))))
    (concat
     (propertize icon-char 'face `(:inherit ,face) 'display `(height ,verdict-icon-height))
     (propertize " "  'face `(:inherit ,face)))))

(defun verdict--render-message (severity message)
  "Return propertized group icon string for ICON-CHAR."
  (if (eq severity 'error)
      (propertize message 'face 'verdict-error-face)
    message))

;;; Alist-Tree → List-Tree Conversion

(defun verdict--output-node (parent-id parent-label output)
  "Return a synthetic *output* leaf plist for PARENT-ID with OUTPUT."
  (list :id     (format "output-%s" parent-id)
        :label  (propertize "<init>" 'face 'verdict-init-face)
        :title  parent-label
        :output output
        :status nil))

(defun verdict--alist-tree-to-list (alist-tree)
  "Convert an alist-tree of verdict nodes to a flat list for treemacs.
Recursively converts :children and computes aggregate :status for groups.
Injects a synthetic *output* child for any suite or group with :output."
  (mapcar
   (lambda (pair)
     (let* ((node     (cdr pair))
            (id       (plist-get node :id))
            (children (plist-get node :children))
            (output   (plist-get node :output)))
       (cond
         (children
          (let* ((child-list (verdict--alist-tree-to-list children))
                 (child-list (if output
                                 (cons (verdict--output-node id (plist-get node :label) output) child-list)
                               child-list))
                 (agg-status (verdict--worst-status
                              (mapcar (lambda (c) (plist-get c :status)) child-list)))
                 (copy       (copy-sequence node)))
            (plist-put copy :children child-list)
            (plist-put copy :status agg-status)
            copy))
         ((and output (plist-member node :children))
          ;; No real children but has output (e.g. compilation failure): inject output child,
          ;; keep explicit status rather than aggregating.
          (let ((copy (copy-sequence node)))
            (plist-put copy :children (list (verdict--output-node id (plist-get node :label) output)))
            copy))
         (t node))))
   alist-tree))

;;; Treemacs Node Types

(treemacs-define-expandable-node-type verdict-node
  :closed-icon (if (plist-get item :children)
                   (verdict--group-icon (plist-get item :status) nil)
                 (verdict--leaf-icon (plist-get item :status)))
  :open-icon   (if (plist-get item :children)
                   (verdict--group-icon (plist-get item :status) t)
                 (verdict--leaf-icon (plist-get item :status)))
  :label       (plist-get item :label)
  :key         (plist-get item :id)
  :children    (plist-get item :children)
  :child-type  'verdict-node
  :ret-action           #'verdict--toggle-or-visit
  :double-click-action  #'verdict--toggle-or-visit)

(treemacs-define-variadic-entry-node-type verdict-root
  :key        "verdict-root"
  :children   verdict-model
  :child-type 'verdict-node)

;;; Output Buffer

(defun verdict-output-back ()
  "Quit the verdict output buffer and return to the verdict buffer."
  (interactive)
  (quit-window nil (selected-window))
  (when-let ((buf (get-buffer verdict-buffer-name)))
    (select-window (or (get-buffer-window buf)
                       (display-buffer buf)))))

(defvar verdict-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "b") #'verdict-output-back)
    map)
  "Keymap for verdict output buffer.")

(define-derived-mode verdict-output-mode special-mode "Verdict Output"
  "Major mode for the verdict test output buffer."
  :keymap verdict-output-mode-map)

;;; Visit / Toggle Actions

(defun verdict--visit (&optional _arg)
  "Navigate to test file/line for node at point.
If the node has log output or an error message, display it in *verdict-output* first."
  (interactive "P")
  (let* ((btn    (treemacs-node-at-point))
         (item   (treemacs-button-get btn :item))
         (file   (plist-get item :file))
         (line   (or (plist-get item :line) 1))
         (label  (or (plist-get item :title) (plist-get item :label)))
         (output (plist-get item :output)))
    (with-current-buffer (get-buffer-create "*verdict-output*")
      (verdict-output-mode)
      (let (buffer-read-only)
        (erase-buffer)
        (when label
          (let ((sep (propertize (make-string (length label) ?─) 'face 'verdict-name-face)))
            (insert sep)
            (insert "\n")
            (insert (propertize label 'face 'verdict-name-face))
            (insert "\n")
            (insert sep)
            (insert "\n\n")))
        (when output
          (insert (ansi-color-apply output)))
        (goto-char (point-min)))
      (display-buffer (current-buffer) '(display-buffer-below-selected)))
    (when file
      (find-file-other-window file)
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun verdict--toggle-or-visit (&optional _arg)
  "Expand/collapse group nodes; navigate to file/line for leaf nodes."
  (interactive "P")
  (let* ((btn  (treemacs-node-at-point))
         (item (treemacs-button-get btn :item)))
    (if (null (plist-get item :children))
        (verdict--visit)
      (treemacs-TAB-action))))

;;; Path Traversal Helpers

(defun verdict--get-at-path (data path)
  "Return value in DATA at PATH.
Keyword keys use plist-get; other keys use alist-get with equal."
  (if (null path) data
    (let* ((key (car path))
           (val (if (keywordp key)
                    (plist-get data key)
                  (alist-get key data nil nil #'equal))))
      (verdict--get-at-path val (cdr path)))))

(defun verdict--update-at-path (data path fn)
  "Return new DATA with value at PATH replaced by (funcall FN current).
FN returning nil deletes an alist entry."
  (if (null path) (funcall fn data)
    (let* ((key  (car path))
           (rest (cdr path)))
      (if (keywordp key)
          (plist-put (copy-sequence data) key
                     (verdict--update-at-path (plist-get data key) rest fn))
        (let* ((existing (assoc key data #'equal))
               (current  (cdr existing))
               (new-val  (verdict--update-at-path current rest fn)))
          (cond
            ((and new-val existing)
             ;; Update in place — preserves insertion order
             (mapcar (lambda (pair)
                       (if (equal (car pair) key) (cons key new-val) pair))
                     data))
            (new-val
             ;; New key — append at end
             (append data (list (cons key new-val))))
            (t
             (assoc-delete-all key data #'equal))))))))

;;; Render

(defun verdict--schedule-render ()
  "Schedule a render in 0.1 seconds, if one is not already pending."
  (unless verdict--render-timer
    (setq verdict--render-timer
          (run-with-timer 0.1 nil #'verdict--render))))

(defun verdict--render ()
  "Convert state to display model and refresh the verdict buffer. Returns the verdict buffer"
  (setq verdict--render-timer nil)
  (setq verdict-model (verdict--alist-tree-to-list verdict--nodes))

  ;; Avoid accidental shadowing of treemacs-initialize by the deprecated treemacs-extensions
  (when (s-contains? "treemacs-extensions" (symbol-file 'treemacs-initialize 'defun))
    (load-library "treemacs-treelib"))

  (with-current-buffer (get-buffer-create verdict-buffer-name)
    (if (eq major-mode 'treemacs-mode)
        (let ((saved-point (point)))
          (treemacs-with-writable-buffer
           (erase-buffer)
           (treemacs--render-extension (treemacs--ext-symbol-to-instance 'verdict-root) 99))
          (goto-char (min saved-point (point-max)))
          (when (fboundp 'hl-line-highlight)
            (hl-line-highlight)))
      (treemacs-initialize verdict-root :with-expand-depth 99)
      (setq-local mode-line-format " %b"))
    (current-buffer)))

;;; Public API

(defun verdict--spinner-tick ()
  "Advance spinner frame and schedule a render."
  (setq verdict--spinner-frame
        (mod (1+ verdict--spinner-frame) (length verdict--spinner-frames)))
  (verdict--schedule-render))

(defun verdict--spinner-start ()
  "Start the spinner timer."
  (setq verdict--spinner-frame 0)
  (unless verdict--spinner-timer
    (setq verdict--spinner-timer
          (run-with-timer 0.15 0.15 #'verdict--spinner-tick))))

(defun verdict--spinner-stop ()
  "Stop the spinner timer."
  (when verdict--spinner-timer
    (cancel-timer verdict--spinner-timer)
    (setq verdict--spinner-timer nil)))

(defun verdict-reset ()
  "Clear all internal verdict state. Does not render."
  (verdict--spinner-stop)
  (setq verdict--nodes nil)
  (clrhash verdict--paths)
  (clrhash verdict--loading-tests)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (setq verdict-model nil))


(defun verdict--maybe-save-buffer ()
  "Save the current buffer before a run, respecting `verdict-save-before-run'."
  (when (buffer-modified-p)
    (pcase verdict-save-before-run
      ('yes (save-buffer))
      ('no  nil)
      (_    ;; nil: present all options in one prompt
       (pcase (read-answer
               (format "Save %s before running tests? " (buffer-name))
               '(("yes"    ?y "save this time")
                 ("no"     ?n "don't save this time")
                 ("always" ?a "always save")
                 ("never"  ?N "never save")))
         ("yes"    (save-buffer))
         ("no"     nil)
         ("always" (save-buffer)
                   (customize-save-variable 'verdict-save-before-run 'yes))
         ("never"  (customize-save-variable 'verdict-save-before-run 'no)))))))

(defun verdict-start (type name)
  "Reset state and display the (empty) verdict buffer.
TYPE is one of :project :file :group :test. NAME is a string or nil."
  (verdict--maybe-save-buffer)
  (verdict-reset)
  (verdict--spinner-start)
  (display-buffer (verdict--render) '(nil (inhibit-same-window . t))))

(defun verdict-stop ()
  "Mark all running nodes as stopped and render."
  (verdict--spinner-stop)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (maphash
   (lambda (_id path)
     (let ((node (verdict--get-at-path verdict--nodes path)))
       (when (eq (plist-get node :status) 'running)
         (setq verdict--nodes
               (verdict--update-at-path verdict--nodes
                                        (append path (list :status))
                                        (lambda (_) 'stopped))))))
   verdict--paths)
  (verdict--render))

(defun verdict-event (event)
  "Process an EVENT plist and update internal state, then schedule a render.
EVENT must have a :type field with a keyword value."
  (when verdict-log-events
    (message "verdict: Received event %s" event))
  (pcase (plist-get event :type)
    (:group
     (let* ((id        (plist-get event :id))
            (parent-id (plist-get event :parent-id))
            (name      (plist-get event :name))
            (file      (plist-get event :file))
            (line-num  (plist-get event :line))
            (file-id   (plist-get event :file-id)))
       (let* ((parent-path (when parent-id
                              (or (gethash parent-id verdict--paths)
                                  (list file-id))))
              (group-path  (if parent-path
                               (append parent-path (list :children id))
                             (list id)))
              (node        (list :id       id
                                 :label    name
                                 :file     file
                                 :line     line-num
                                 :children nil)))
         (setq verdict--nodes
               (verdict--update-at-path verdict--nodes group-path (lambda (_) node)))
         (puthash id group-path verdict--paths))))

    (:test-start
     (let* ((id        (plist-get event :id))
            (name      (plist-get event :name))
            (group-ids (plist-get event :group-ids))
            (line-num  (plist-get event :line))
            (file-id   (plist-get event :file-id))
            (url       (plist-get event :url)))
       (if (and (stringp name) (string-match-p "^loading " name))
           (puthash id file-id verdict--loading-tests)
         (let* ((parent-path (verdict--innermost-group-path group-ids file-id))
                (test-path   (append parent-path (list :children id)))
                (file        (when (and (stringp url) (not (string-empty-p url)))
                               (verdict--url-to-file url)))
                (node        (list :id     id
                                   :label  name
                                   :status 'running
                                   :file   file
                                   :line   line-num)))
           (setq verdict--nodes
                 (verdict--update-at-path verdict--nodes test-path (lambda (_) node)))
           (puthash id test-path verdict--paths)))))

    (:log
     (let* ((id       (plist-get event :id))
            (severity (plist-get event :severity))
            (msg      (verdict--render-message severity (plist-get event :message)))
            (path     (gethash id verdict--paths)))
       (when msg
         (let ((output-path (if path
                                (append path (list :output))
                              (when-let ((file-id (gethash id verdict--loading-tests)))
                                (list file-id :output)))))
           (when output-path
             (setq verdict--nodes
                   (verdict--update-at-path verdict--nodes output-path
                                            (lambda (prev)
                                              (if prev (concat prev "\n" msg) msg)))))))))

    (:test-done
     (let* ((id        (plist-get event :id))
            (result    (plist-get event :result))
            (test-path (gethash id verdict--paths)))
         (when test-path
           (setq verdict--nodes
                 (verdict--update-at-path verdict--nodes
                                          (append test-path (list :status))
                                          (lambda (_) result))))
         (unless test-path
           (when-let ((file-id (gethash id verdict--loading-tests)))
             (unless (eq result 'success)
               (setq verdict--nodes
                     (verdict--update-at-path verdict--nodes
                                              (list file-id :status)
                                              (lambda (_) 'error))))))))

    (:done
     (message "verdict: test run complete")))

  (verdict--schedule-render))

;;; Internal Helpers

(defun verdict--innermost-group-path (group-ids file-id)
  "Return path to innermost known group from GROUP-IDS, falling back to FILE-ID."
  (let ((ids (reverse (append group-ids nil)))
        (result nil))
    (while (and ids (not result))
      (when-let ((path (gethash (car ids) verdict--paths)))
        (setq result path))
      (setq ids (cdr ids)))
    (or result (list file-id))))

(defun verdict--url-to-file (url)
  "Convert a file:// URL to a local file path."
  (if (string-prefix-p "file://" url)
      (substring url 7)
    url))

;;; Debug

(defun verdict-debug-at-point ()
  "Print debug info about the verdict node at point."
  (interactive)
  (let ((btn (treemacs-node-at-point)))
    (if (null btn)
        (message "verdict: no button at point")
      (let* ((state (treemacs-button-get btn :state))
             (depth (treemacs-button-get btn :depth))
             (path  (treemacs-button-get btn :path))
             (item  (treemacs-button-get btn :item))
             (kids  (and item (plist-get item :children))))
        (message "verdict: state=%s depth=%s path=%s children=%s"
                 state depth path
                 (if kids (format "(%d items)" (length kids)) "nil"))))))

(provide 'verdict)
;;; verdict.el ends here
