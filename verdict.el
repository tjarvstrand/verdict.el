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

;;; Braille font detection

(defconst verdict--braille-fonts
  '("Symbola"
    "Apple Symbols"
    "Segoe UI Symbol"
    "Arial Unicode MS"
    "DejaVu Sans"
    "Noto Sans Symbols2"
    "FreeSans"
    "GNU Unifont")
  "Priority list of fonts known to support Braille Unicode (U+2800–U+28FF).")

(defun verdict--detect-braille-font ()
  "Return the first font from `verdict--braille-fonts' available on this system."
  (let ((available (font-family-list)))
    (seq-find (lambda (font) (member font available))
              verdict--braille-fonts)))

(defvar verdict--auto-braille-font (verdict--detect-braille-font)
  "First Braille-capable font detected at load time, or nil.")

;;; Customization

(defcustom verdict-icon-font verdict--auto-braille-font
  "Font family to use for verdict status icons.
When non-nil, icons are rendered with `:family FONT' in their face spec.
Defaults to the first font from `verdict--braille-fonts' found in
`font-family-list', or nil if none is available."
  :type '(choice (const :tag "Default" nil) string)
  :group 'verdict)

(defcustom verdict-spinner-style (if verdict--auto-braille-font 'braille 'ascii)
  "Spinner style to use while tests are running.
`braille' uses Unicode Braille characters for a smooth animation.
`ascii'   uses plain ASCII characters (|, /, -, \\\\).
Defaults to `braille' if a suitable font was auto-detected at load time."
  :type '(choice (const :tag "Braille" braille) (const :tag "ASCII" ascii))
  :group 'verdict)

(defcustom verdict-icon-height 1.2
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

(defvar verdict--nodes (make-hash-table :test #'equal)
  "Hash table mapping node id to its plist.")

(defvar verdict--root-ids nil
  "Ordered list of root node IDs.")

(defvar verdict--render-timer nil
  "Debounce timer for rendering.")

(defconst verdict--spinner-frames-ascii ["|" "/" "-" "\\"]
  "ASCII animation frames for the running spinner.")

(defconst verdict--spinner-frames-braille ["⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷"]
  "Braille animation frames for the running spinner.")

(defun verdict--spinner-frames ()
  "Return the spinner frame vector for the current `verdict-spinner-style'."
  (if (eq verdict-spinner-style 'braille)
      verdict--spinner-frames-braille
    verdict--spinner-frames-ascii))

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
                 ('running (aref (verdict--spinner-frames) verdict--spinner-frame))
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
  (let* ((face (verdict--status-face (verdict--effective-status status)))
         (icon-face (if verdict-icon-font
                        `(:inherit ,face :family ,verdict-icon-font)
                      `(:inherit ,face))))
    (concat
     (propertize icon-char 'face icon-face 'display `(height ,verdict-icon-height))
     (propertize " "  'face `(:inherit ,face)))))

(defun verdict--render-message (severity message)
  "Return propertized group icon string for ICON-CHAR."
  (if (eq severity 'error)
      (propertize message 'face 'verdict-error-face)
    message))

;;; Build Display Tree

(defun verdict--output-node (parent-id parent-label output)
  "Return a synthetic *output* leaf plist for PARENT-ID with OUTPUT."
  (list :id     (format "output-%s" parent-id)
        :label  (propertize "<init>" 'face 'verdict-init-face)
        :title  parent-label
        :output output
        :status nil))

(defun verdict--build-tree (ids)
  "Build a nested tree of node plists from IDS by resolving children.
Recursively resolves :children IDs, computes aggregate :status for groups,
and injects a synthetic *output* child for any group with :output."
  (mapcar
   (lambda (id)
     (let* ((node       (gethash id verdict--nodes))
            (child-ids  (plist-get node :children))
            (output     (plist-get node :output)))
       (cond
         (child-ids
          (let* ((child-list (verdict--build-tree child-ids))
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
   ids))

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

;;; Node Helpers

(defun verdict--add-child (parent-id child-id)
  "Append CHILD-ID to the :children list of the node at PARENT-ID."
  (let* ((parent (gethash parent-id verdict--nodes))
         (updated-children (append (plist-get parent :children) (list child-id)))
         (updated-parent (plist-put parent :children updated-children)))
    (puthash parent-id updated-parent verdict--nodes)))

;;; Render

(defun verdict--schedule-render ()
  "Schedule a render in 0.1 seconds, if one is not already pending."
  (unless verdict--render-timer
    (setq verdict--render-timer
          (run-with-timer 0.1 nil #'verdict--render))))

(defun verdict--render ()
  "Convert state to display model and refresh the verdict buffer. Returns the verdict buffer"
  (setq verdict--render-timer nil)
  (setq verdict-model (verdict--build-tree verdict--root-ids))

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
        (mod (1+ verdict--spinner-frame) (length (verdict--spinner-frames))))
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
  (clrhash verdict--nodes)
  (setq verdict--root-ids nil)
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
   (lambda (id node)
     (when (eq (plist-get node :status) 'running)
       (puthash id (plist-put node :status 'stopped) verdict--nodes)))
   verdict--nodes)
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
            (node      (list :id       id
                             :label    (plist-get event :name)
                             :file     (plist-get event :file)
                             :line     (plist-get event :line)
                             :children nil)))
       (puthash id node verdict--nodes)
       (if (gethash parent-id verdict--nodes)
           (verdict--add-child parent-id id)
         (setq verdict--root-ids (append verdict--root-ids (list id))))))

    (:test-start
     (let* ((id        (plist-get event :id))
            (parent-id (plist-get event :parent-id))
            (node      (list :id     id
                             :label  (plist-get event :name)
                             :status 'running
                             :file   (plist-get event :file)
                             :line   (plist-get event :line))))
       (puthash id node verdict--nodes)
       (verdict--add-child parent-id id)))

    (:log
     (let* ((id     (plist-get event :id))
            (msg    (verdict--render-message (plist-get event :severity) (plist-get event :message)))
            (node   (gethash id verdict--nodes)))
       (when (and msg node)
         (let ((prev (plist-get node :output)))
           (plist-put node :output (if prev (concat prev "\n" msg) msg))))))

    (:test-done
     (when-let ((node (gethash (plist-get event :id) verdict--nodes)))
       (plist-put node :status (plist-get event :result))))

    (:done
     (message "verdict: test run complete")))

  (verdict--schedule-render))

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
