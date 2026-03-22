;;; verdict.el --- Generic test runner with treemacs results UI -*- lexical-binding: t -*-
;;
;; Package-Requires: ((emacs "30.0") (treemacs "2.0") (dash "2.0") (s "1.0"))

(require 'treemacs-treelib)
(require 'ansi-color)
(require 'dash)
(require 's)

;; TODO
;; - [Dart] Add links to stack traces in output
;; - Fix keybindings and mouse actions
;; - Output filter
;; - Jump to next failure
;; - Add a module scope
;; - Stop link/keybinding

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

;; Mode-line face variants

(defface verdict-success-mode-line-face
  '((t :inherit verdict-success-face))
  "Face for passed tests in inactive mode line.")

(defface verdict-success-mode-line-active-face
  '((t :inherit verdict-success-face))
  "Face for passed tests in active mode line.")

(defface verdict-error-mode-line-face
  '((t :inherit verdict-error-face))
  "Face for failed tests in inactive mode line.")

(defface verdict-error-mode-line-active-face
  '((t :inherit verdict-error-face))
  "Face for failed tests in active mode line.")

(defface verdict-skipped-mode-line-face
  '((t :inherit verdict-skipped-face))
  "Face for skipped tests in inactive mode line.")

(defface verdict-skipped-mode-line-active-face
  '((t :inherit verdict-skipped-face))
  "Face for skipped tests in active mode line.")

(defface verdict-running-mode-line-face
  '((t :inherit verdict-running-face))
  "Face for running tests in inactive mode line.")

(defface verdict-running-mode-line-active-face
  '((t :inherit verdict-running-face))
  "Face for running tests in active mode line.")

(defface verdict-stopped-mode-line-face
  '((t :inherit verdict-stopped-face))
  "Face for stopped tests in inactive mode line.")

(defface verdict-stopped-mode-line-active-face
  '((t :inherit verdict-stopped-face))
  "Face for stopped tests in active mode line.")

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

(defcustom verdict-icon-height 1.0
  "Relative height of verdict status icons, as a float (1.0 = normal size)."
  :type 'number
  :group 'verdict)

(defcustom verdict-icon-open    "▼" "Icon for expanded group/file nodes."  :type 'string :group 'verdict)
(defcustom verdict-icon-closed  "▶" "Icon for collapsed group/file nodes." :type 'string :group 'verdict)
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

(defvar verdict--output-node-id nil
  "ID of the verdict--nodes entry currently shown in *verdict-output*, or nil.")

(defvar verdict--run-state nil
  "Current run state: nil, `running', or `finished'.")


(defvar verdict-buffer-name "*verdict*"
  "Name of the verdict results buffer.")

(defvar verdict-log-events nil
  "Whether to print runner events to the messages buffer")

;;; Backend Registration

(defvar verdict--backends nil
  "Alist of (PREDICATE . BACKEND-PLIST) entries, most recently registered first.
PREDICATE is one of:
  - a major-mode symbol  — matched with `derived-mode-p'
  - a regexp string      — matched against `buffer-name'
  - a function           — called with no args; non-nil means match
BACKEND-PLIST keys:
  :context-fn   — function (scope &optional file-tests) → backend-specific context plist;
                  called in source buffer.  When FILE-TESTS is provided (an alist
                  of (FILE . (NAME ...)) entries), use it instead of deriving
                  from the buffer.
  :command-fn   — function (context debug) → plist with :command :directory :name.
                  :command may be a list (verdict manages the process) or a function
                  (custom launch; fn must call `verdict-stop' when done)
  :line-handler — function (line) called per complete output line")

(defun verdict--match-predicate (predicate)
  "Return non-nil if PREDICATE matches the current buffer."
  (cond
   ((symbolp predicate)   (derived-mode-p predicate))
   ((stringp predicate)   (string-match-p predicate (buffer-name)))
   ((functionp predicate) (funcall predicate))
   (t (error "Invalid verdict backend predicate: %S" predicate))))

(defun verdict--active-backend ()
  "Return the first registered backend whose predicate matches the current buffer."
  (or (cdr (seq-find (lambda (entry)
                       (verdict--match-predicate (car entry)))
                     verdict--backends))
      (error "No verdict backend matches buffer %s (mode: %s)"
             (buffer-name) major-mode)))

(defun verdict-register-backend (predicate context-fn command-fn line-handler)
  "Register a backend with PREDICATE, CONTEXT-FN, COMMAND-FN, and LINE-HANDLER.
See `verdict--backends' for the supported predicate forms."
  (add-to-list 'verdict--backends
               (cons predicate (list :context-fn   context-fn
                                     :command-fn   command-fn
                                     :line-handler line-handler))))

;;; Process State

(defvar verdict--proc nil
  "Active test process.")

(defvar verdict--partial ""
  "Partial line buffer for streaming process output.")

(defvar verdict--proc-backend nil
  "Backend plist for the currently running (or last completed) process.")

(defvar verdict--last-backend nil
  "Backend plist from the last run, for rerun.")

(defvar verdict--last-context nil
  "Context plist from the last run, for rerun.")

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

(defun verdict--leaf-icon (status)
  "Return 2-char propertized icon string for leaf node with STATUS."
  (let* ((icon (pcase status
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
  (let* ((face (verdict--status-face status))
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
  (list :id        (format "output-%s" parent-id)
        :source-id parent-id
        :label     (propertize "<init>" 'face 'verdict-init-face)
        :title     parent-label
        :output    output
        :status    nil))

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
  :label       (verdict--node-label item)
  :key         (plist-get item :id)
  :children    (plist-get item :children)
  :child-type  'verdict-node
  :ret-action           #'verdict--toggle-or-show-output
  :double-click-action  #'verdict--toggle-or-show-output)

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

(defun verdict--write-output-buffer (label output)
  "Erase *verdict-output* and write LABEL header followed by OUTPUT."
  (unless (eq major-mode 'verdict-output-mode)
    (verdict-output-mode))
  (let (buffer-read-only)
    (erase-buffer)
    (let ((sep (propertize (make-string (length label) ?─) 'face 'verdict-name-face)))
      (insert sep "\n" (propertize label 'face 'verdict-name-face) "\n" sep "\n\n"))
    (when output
      (insert (ansi-color-apply output)))))

(defun verdict--append-output-buffer (id prev msg)
  "Append MSG to *verdict-output* if it is open and showing node ID.
PREV is the node's :output before this message; used to add a newline separator."
  (when (equal id verdict--output-node-id)
    (when-let* ((buf (get-buffer "*verdict-output*"))
                ((get-buffer-window buf)))
      (with-current-buffer buf
        (let (buffer-read-only)
          (when prev (insert "\n"))
          (insert (ansi-color-apply msg)))))))

(defun verdict--show-output (&optional _arg)
  "Display output for the node at point in *verdict-output*."
  (interactive "P")
  (let* ((btn    (treemacs-node-at-point))
         (item   (treemacs-button-get btn :item))
         (id     (or (plist-get item :source-id) (plist-get item :id)))
         (label  (or (plist-get item :title) (plist-get item :label)))
         (output (plist-get item :output)))
    (setq verdict--output-node-id id)
    (with-current-buffer (get-buffer-create "*verdict-output*")
      (verdict--write-output-buffer label output)
      (display-buffer (current-buffer) '(display-buffer-below-selected)))))

(defun verdict--visit (&optional _arg)
  "Navigate to test file/line for node at point."
  (interactive "P")
  (let* ((btn  (treemacs-node-at-point))
         (item (treemacs-button-get btn :item))
         (file (plist-get item :file))
         (line (or (plist-get item :line) 1)))
    (when file
      (find-file-other-window file)
      (goto-char (point-min))
      (forward-line (1- line)))))

(defvar verdict--visit-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'verdict--visit-link-click)
    map)
  "Keymap for the visit-file link icon in verdict nodes.")

(defun verdict--visit-link-click (event)
  "Visit the file/line for the node whose link icon was clicked."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (when pos
      (goto-char pos)
      (verdict--visit))))

(defun verdict--visit-link (file)
  "Return a propertized link icon string when FILE is non-nil."
  (when file
    (propertize " ↗" 'face 'link
                     'keymap verdict--visit-link-keymap
                     'mouse-face 'highlight
                     'help-echo "Visit file")))

(defun verdict--rerun-at-node ()
  "Rerun the test/group at point in the verdict buffer."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (unless verdict--last-backend (error "No previous verdict backend"))
  (let* ((btn        (treemacs-node-at-point))
         (item       (treemacs-button-get btn :item))
         (file       (plist-get item :file))
         (name       (plist-get item :name))
         (file-tests (when file
                       (list (if name (list file name) (list file)))))
         (context    (funcall (plist-get verdict--last-backend :context-fn)
                              :file file-tests)))
    (verdict--launch verdict--last-backend context nil)))

(defvar verdict--rerun-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'verdict--rerun-link-click)
    map)
  "Keymap for the rerun link icon in verdict nodes.")

(defun verdict--rerun-link-click (event)
  "Rerun the test/group whose rerun link was clicked."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (when pos
      (goto-char pos)
      (verdict--rerun-at-node))))

(defun verdict--rerun-link (item)
  "Return a propertized rerun link string, or nil for output nodes."
  (unless (plist-get item :source-id)
    (propertize " ⟲" 'face 'link
                      'keymap verdict--rerun-link-keymap
                      'mouse-face 'highlight
                      'help-echo "Rerun")))

(defun verdict--node-label (item)
  "Return the display label for ITEM, with visit and rerun links."
  (concat (plist-get item :label)
          (verdict--visit-link (plist-get item :file))
          (verdict--rerun-link item)))

(defun verdict--toggle-or-show-output (&optional _arg)
  "Expand/collapse group nodes; show output for leaf nodes."
  (interactive "P")
  (let* ((btn  (treemacs-node-at-point))
         (item (treemacs-button-get btn :item)))
    (if (plist-get item :children)
        (treemacs-TAB-action)
      (verdict--show-output))))


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
      (setq-local mode-line-format verdict--mode-line-format)
      (local-set-key (kbd "M-RET") #'verdict--visit)
      (local-set-key (kbd "r") #'verdict--rerun-at-node)
      (local-set-key (kbd "f") #'verdict-rerun-failed))
    (current-buffer)))

;;; Public API

(defun verdict--spinner-tick ()
  "Advance spinner frame and schedule a render."
  (setq verdict--spinner-frame
        (mod (1+ verdict--spinner-frame) (length (verdict--spinner-frames))))
  (verdict--update-mode-line)
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

;;; Mode Line

(defun verdict--mode-line-face (face)
  "Return the mode-line variant of FACE for the current window."
  (let ((suffix (if (mode-line-window-selected-p) "-mode-line-active-face" "-mode-line-face")))
    (intern (concat (string-remove-suffix "-face" (symbol-name face)) suffix))))

(defun verdict--count-by-status ()
  "Return an alist of (status . count) for all leaf nodes."
  (let ((counts nil))
    (maphash (lambda (_id node)
               (unless (plist-member node :children)
                 (let* ((status (plist-get node :status))
                        (entry  (assq status counts)))
                   (if entry
                       (setcdr entry (1+ (cdr entry)))
                     (push (cons status 1) counts)))))
             verdict--nodes)
    counts))

(defun verdict--mode-line-string ()
  "Return the mode line string for the verdict buffer."
  (pcase verdict--run-state
    ('running
     (let* ((spinner (aref (verdict--spinner-frames) verdict--spinner-frame))
            (base (verdict--mode-line-face 'verdict-running-face))
            (face (if verdict-icon-font
                      `(:inherit ,base :family ,verdict-icon-font)
                    base)))
       (concat " *verdict* " (propertize spinner 'face face) " Running…")))
    ('finished
     (let* ((counts (verdict--count-by-status))
            (passed  (or (cdr (assq 'passed counts)) 0))
            (failed  (or (cdr (assq 'failed counts)) 0))
            (errored (or (cdr (assq 'error counts)) 0))
            (skipped (or (cdr (assq 'skipped counts)) 0))
            (stopped (or (cdr (assq 'stopped counts)) 0))
            (total   (+ passed failed errored skipped stopped))
            (parts   nil))
       (when (> stopped 0)
         (push (propertize (format "%d stopped" stopped) 'face (verdict--mode-line-face 'verdict-stopped-face)) parts))
       (when (> skipped 0)
         (push (propertize (format "%d skipped" skipped) 'face (verdict--mode-line-face 'verdict-skipped-face)) parts))
       (when (> errored 0)
         (push (propertize (format "%d error" errored) 'face (verdict--mode-line-face 'verdict-error-face)) parts))
       (when (> failed 0)
         (push (propertize (format "%d failed" failed) 'face (verdict--mode-line-face 'verdict-error-face)) parts))
       (push (propertize (format "%d passed" passed) 'face (verdict--mode-line-face 'verdict-success-face)) parts)
       (format " *verdict* %s — %d tests" (string-join parts ", ") total)))
    (_ " *verdict*")))

(defvar verdict--mode-line-format
  '(:eval (verdict--mode-line-string))
  "Mode line construct for the verdict buffer.")

(defun verdict--update-mode-line ()
  "Force a mode line update in the verdict buffer."
  (when-let ((buf (get-buffer verdict-buffer-name)))
    (with-current-buffer buf
      (force-mode-line-update))))

(defun verdict-reset ()
  "Clear all internal verdict state. Does not render."
  (verdict--spinner-stop)
  (clrhash verdict--nodes)
  (setq verdict--root-ids nil)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (setq verdict-model nil)
  (setq verdict--output-node-id nil)
  (setq verdict--run-state nil))


(defun verdict--maybe-save-buffer ()
  "Save the current buffer before a run, respecting `verdict-save-before-run'."
  (when (and (buffer-modified-p) (buffer-file-name))
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
  (setq verdict--run-state 'running)
  (verdict--spinner-start)
  (let ((buf (verdict--render)))
    (unless (get-buffer-window buf)
      (display-buffer buf '(nil (inhibit-same-window . t))))))

(defun verdict-stop ()
  "Mark all running nodes as stopped and render."
  (verdict--spinner-stop)
  (setq verdict--run-state 'finished)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (maphash
   (lambda (id node)
     (when (eq (plist-get node :status) 'running)
       (puthash id (plist-put node :status 'stopped) verdict--nodes)))
   verdict--nodes)
  (verdict--render)
  (verdict--update-mode-line))

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
            (node      (list :id       id
                             :name     name
                             :label    (or (plist-get event :label) name)
                             :status   'running
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
            (name      (plist-get event :name))
            (node      (list :id     id
                             :name   name
                             :label  (or (plist-get event :label) name)
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
           (plist-put node :output (if prev (concat prev "\n" msg) msg))
           (verdict--append-output-buffer id prev msg)))))

    (:test-done
     (when-let ((node (gethash (plist-get event :id) verdict--nodes)))
       (plist-put node :status (plist-get event :result))))

    (:done
     (setq verdict--run-state 'finished)
     (verdict--update-mode-line)
     (message "verdict: test run complete")))

  (verdict--schedule-render))

;;; Generic Process Infrastructure

(defun verdict--filter (_proc chunk)
  "Accumulate CHUNK into line buffer; call backend line-handler per complete line."
  (let* ((handler (plist-get verdict--proc-backend :line-handler))
         (full    (concat verdict--partial chunk))
         (parts   (split-string full "\n"))
         (rest    (car (last parts))))
    (setq verdict--partial rest)
    (dolist (line (butlast parts))
      (funcall handler line))))

(defun verdict--sentinel (proc event)
  "Flush partial buffer and finalize state when process exits."
  (let ((handler (plist-get verdict--proc-backend :line-handler)))
    (unless (string-empty-p verdict--partial)
      (funcall handler verdict--partial)
      (setq verdict--partial "")))
  (when (eq proc verdict--proc)
    (verdict-stop))
  (message "verdict: process %s" (string-trim event)))

(defun verdict--launch (backend context debug)
  "Launch a test process for CONTEXT with DEBUG using BACKEND."
  (setq verdict--proc-backend backend)
  (when (process-live-p verdict--proc)
    (kill-process verdict--proc))
  (setq verdict--partial "")
  (let* ((spec (funcall (plist-get backend :command-fn) context debug))
         (cmd  (plist-get spec :command))
         (dir  (or (plist-get spec :directory) default-directory))
         (name (plist-get spec :name))
         (default-directory dir))
    (verdict-start nil name)
    (if (functionp cmd)
        (funcall cmd)
      (setq verdict--proc
            (make-process
             :name            "verdict"
             :command         cmd
             :connection-type 'pty
             :filter          #'verdict--filter
             :sentinel        #'verdict--sentinel
             :noquery         t))
      (message "verdict: running %s" (string-join cmd " "))
      (message "verdict: in %s" dir))))

(defun verdict--run (scope debug)
  "Run tests for SCOPE using the backend matching the current buffer.
DEBUG is passed to the backend's command function."
  (let* ((backend (verdict--active-backend))
         (context (funcall (plist-get backend :context-fn) scope)))
    (setq verdict--last-backend backend)
    (setq verdict--last-context context)
    (verdict--launch backend context debug)))

;;; Public Run Commands

(defun verdict-run-at-point ()   (interactive) (verdict--run :at-point nil))
(defun verdict-run-group ()      (interactive) (verdict--run :group nil))
(defun verdict-run-file ()       (interactive) (verdict--run :file nil))
(defun verdict-run-project ()    (interactive) (verdict--run :project nil))
(defun verdict-debug-at-point () (interactive) (verdict--run :at-point t))
(defun verdict-debug-group ()    (interactive) (verdict--run :group t))
(defun verdict-debug-file ()     (interactive) (verdict--run :file t))
(defun verdict-debug-project ()  (interactive) (verdict--run :project t))

(defun verdict-run-last ()
  "Rerun the last test run."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (verdict--launch verdict--last-backend verdict--last-context nil))

(defun verdict-debug-last ()
  "Rerun the last test run with debugging."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (verdict--launch verdict--last-backend verdict--last-context t))

(defun verdict-rerun-failed ()
  "Rerun only the failed tests from the last run."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (unless verdict--last-backend (error "No previous verdict backend"))
  (let ((file-tests nil))
    (maphash (lambda (_id node)
               (when (and (memq (plist-get node :status) '(failed error))
                          (not (plist-member node :children))
                          (plist-get node :name))
                 (let* ((file  (plist-get node :file))
                        (entry (assoc file file-tests)))
                   (if entry
                       (setcdr entry (cons (plist-get node :name) (cdr entry)))
                     (push (list file (plist-get node :name)) file-tests)))))
             verdict--nodes)
    (unless file-tests (error "No failed tests to rerun"))
    (let ((context (funcall (plist-get verdict--last-backend :context-fn)
                            :file file-tests)))
      (verdict--launch verdict--last-backend context nil))))


;;; Minor Mode

(defvar verdict-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t t") #'verdict-run-at-point)
    (define-key map (kbd "C-c t g") #'verdict-run-group)
    (define-key map (kbd "C-c t f") #'verdict-run-file)
    (define-key map (kbd "C-c t p") #'verdict-run-project)
    (define-key map (kbd "C-c t r") #'verdict-run-last)
    (define-key map (kbd "C-c t T") #'verdict-debug-at-point)
    (define-key map (kbd "C-c t G") #'verdict-debug-group)
    (define-key map (kbd "C-c t F") #'verdict-debug-file)
    (define-key map (kbd "C-c t P") #'verdict-debug-project)
    (define-key map (kbd "C-c t R") #'verdict-debug-last)
    map))

(define-minor-mode verdict-mode
  "Minor mode providing verdict test runner keybindings."
  :lighter " verdict"
  :keymap verdict-mode-map)

;;; Debug

(defun verdict--debug-node-at-point ()
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
