;;; verdict.el --- Generic test runner with treemacs results UI -*- lexical-binding: t -*-

;; Author: Thomas Järvstrand <https://github.com/tjarvstrand>
;; Maintainer: Thomas Järvstrand <https://github.com/tjarvstrand>
;; Version: 0.1.3
;; URL: https://github.com/tjarvstrand/verdict.el
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (treemacs "3.0") (dash "2.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Verdict is a generic test runner framework for Emacs that displays
;; results in a treemacs-based UI.  It provides a backend API for
;; language-specific test runners to plug into.  See the README for
;; details on writing a backend for your language of choice.

;;; Code:

(require 'treemacs-treelib)
(require 'ansi-color)
(require 'subr-x)

(declare-function treemacs-define-doubleclick-action "treemacs-mouse-interface")
(require 'dash)
(require 'project)

;;; Customization

(defgroup verdict nil
  "Generic test runner with treemacs results UI."
  :group 'tools
  :prefix "verdict-")

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

(defface verdict-button-face
  '((t :inherit shadow))
  "Face for clickable buttons in verdict buffers.")

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

(defun verdict--default-project-root ()
  "Return the project root using `project.el'."
  (when-let* ((proj (project-current t)))
    (project-root proj)))

(defcustom verdict-project-root-fn #'verdict--default-project-root
  "Function to find the project root directory.
Called with no arguments in the source buffer.  Should return a directory path."
  :type 'function
  :group 'verdict)

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

(defvar verdict--dirty-parent-ids nil
  "Parent ids whose children list/icons need re-rendering on next render.
The symbol `:root' represents the variadic top-level extension node.")

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
  "Repeating timer that advances `verdict--spinner-frame'.
Patches in-tree glyphs in place; does not schedule a render.")

(defvar verdict-model nil
  "List of root node plists (display model, derived from verdict--nodes).")

(defvar verdict--output-node-id nil
  "ID of the verdict--nodes entry currently shown in *verdict-output*, or nil.")

(defvar verdict--run-state nil
  "Current run state: nil, `running', or `finished'.")

(defvar verdict--hidden-statuses nil
  "List of status symbols whose tests are currently hidden in the tree.")

(defvar verdict--status-counts nil
  "Alist of (STATUS . COUNT) for leaf nodes.
Maintained incrementally by `verdict-event' and `verdict-stop'.")

(defcustom verdict-buffer-name "*verdict*"
  "Name of the verdict results buffer."
  :type 'string
  :group 'verdict)

(defcustom verdict-log-events nil
  "If non-nil, log every verdict event to the *Messages* buffer.
Useful for debugging backend implementations."
  :type 'boolean
  :group 'verdict)

;;; Backend Registration

(defvar verdict--backends nil
  "Alist of (PREDICATE . BACKEND-PLIST) entries.
Most recently registered first.
PREDICATE is one of:
  - a major-mode symbol — matched with `derived-mode-p'
  - a regexp string — matched against `buffer-file-name' if the buffer
    is visiting a file, else against `buffer-name'
  - a function — called with no args; non-nil means match
BACKEND-PLIST keys:
  :context-fn — (scope) -> context plist.
    SCOPE: :test-at-point, :group-at-point, :file,
    :module, :project, or (:tests . FILE-TESTS).
  :command-fn — (context debug) -> plist with
    :command   — argv list (subprocess) or function (custom launch).
                 When a function, it is called with no arguments and
                 should return a kill handle: a zero-arg function that
                 stops the run, or nil if no kill mechanism is available.
    :directory — working directory.
    :name      — display name.
    :header    — buffer header string.
  :line-handler — (line) called per output line.")

(defun verdict--match-predicate (predicate)
  "Return non-nil if PREDICATE matches the current buffer.
For regexp predicates, match against `buffer-file-name' when the buffer
visits a file."
  (cond
   ((symbolp predicate)   (derived-mode-p predicate))
   ((stringp predicate)   (string-match-p predicate (or buffer-file-name (buffer-name))))
   ((functionp predicate) (funcall predicate))
   (t (error "Invalid verdict backend predicate: %S" predicate))))

(defun verdict--active-backend ()
  "Return the first registered backend whose predicate matches the current buffer."
  (or (cdr (seq-find (lambda (entry)
                       (verdict--match-predicate (car entry)))
                     verdict--backends))
      (error "No verdict backend matches buffer %s (mode: %s)"
             (buffer-name) major-mode)))

;;;###autoload
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

(defvar verdict--kill-handle nil
  "Function of zero arguments that stops the active test run, or nil.
For subprocess runs, set by `verdict--launch' to a process kill.
For runs whose `:command' is a function, set to that function's
return value.")

(defvar verdict--partial ""
  "Partial line buffer for streaming process output.")

(defvar verdict--proc-backend nil
  "Backend plist for the currently running (or last completed) process.")

(defvar verdict--run-header nil
  "Header string displayed at the top of the verdict buffer.")

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

(defun verdict--bump-status-count (status delta)
  "Add DELTA to the count for STATUS in `verdict--status-counts'."
  (when status
    (cl-callf + (alist-get status verdict--status-counts 0) delta)))

(defun verdict--group-status (id)
  "Return the aggregate status for group ID from its children's :status."
  (let* ((node      (gethash id verdict--nodes))
         (child-ids (plist-get node :children))
         (statuses  (mapcar (lambda (cid)
                              (plist-get (gethash cid verdict--nodes) :status))
                            child-ids)))
    (verdict--worst-status statuses)))

(defun verdict--parent-of (id)
  "Return the parent id of node ID, or nil for a root node."
  (plist-get (gethash id verdict--nodes) :parent-id))

(defun verdict--mark-dirty-parent (parent-id)
  "Record PARENT-ID's children list/icons as needing a re-render.
PARENT-ID nil indicates the variadic top-level (recorded as `:root')."
  (push (or parent-id :root) verdict--dirty-parent-ids))

(defun verdict--propagate-status-up (start-id)
  "Walk up from START-ID, updating each ancestor's :status as aggregates change.
For each ancestor whose :status actually changes, mark its parent dirty."
  (let ((id (verdict--parent-of start-id)))
    (while id
      (let* ((node (gethash id verdict--nodes))
             (old  (plist-get node :status))
             (new  (verdict--group-status id)))
        (if (eq old new)
            (setq id nil)
          (plist-put node :status new)
          (let ((parent (verdict--parent-of id)))
            (verdict--mark-dirty-parent parent)
            (setq id parent)))))))

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
  (let* ((spinner (eq status 'running))
         (icon (pcase status
                 ('running (aref (verdict--spinner-frames) verdict--spinner-frame))
                 ('passed  verdict-icon-passed)
                 ('failed  verdict-icon-failed)
                 ('error   verdict-icon-error)
                 ('skipped verdict-icon-skipped)
                 ('stopped verdict-icon-stopped)
                 (_        " "))))
    (verdict--render-icon status icon spinner)))

(defun verdict--group-icon (status open)
  "Return propertized group icon string for STATUS; OPEN controls arrow direction."
  (verdict--render-icon status (if open verdict-icon-open verdict-icon-closed) nil))

(defun verdict--render-icon (status icon-char &optional spinner)
  "Return propertized icon string for STATUS using ICON-CHAR.
When SPINNER is non-nil, tag ICON-CHAR with `verdict-spinner' so
`verdict--spinner-tick' can patch it in place without re-rendering."
  (let* ((face (verdict--status-face status))
         (icon-face (if verdict-icon-font
                        `(:inherit ,face :family ,verdict-icon-font)
                      `(:inherit ,face)))
         (icon-props (append
                      (when spinner '(verdict-spinner t))
                      `(face ,icon-face display (height ,verdict-icon-height)))))
    (concat
     (apply #'propertize icon-char icon-props)
     (propertize " "  'face `(:inherit ,face)))))

(defun verdict--render-message (severity message)
  "Return a copy of MESSAGE with error face applied when SEVERITY is `error'."
  (let ((msg (copy-sequence message)))
    (when (eq severity 'error)
      (add-face-text-property 0 (length msg) 'verdict-error-face nil msg))
    msg))

;;; Build Display Tree

(defun verdict--output-node (parent-id parent-label output)
  "Return a synthetic *output* leaf plist for PARENT-ID.
PARENT-LABEL is used as the title.  OUTPUT is the log text."
  (list :id        (format "output-%s" parent-id)
        :source-id parent-id
        :label     (propertize "<init>" 'face 'verdict-init-face)
        :title     parent-label
        :output    output
        :status    nil))

(defun verdict--build-tree (ids)
  "Build a nested tree of node plists from IDS by resolving children."
  (delq nil
   (mapcar
    (lambda (id)
      (let* ((node       (gethash id verdict--nodes))
             (child-ids  (plist-get node :children))
             (output     (plist-get node :output)))
        (cond
          (child-ids
           (let* ((child-list (verdict--build-tree child-ids))
                  (child-list (if verdict--hidden-statuses
                                  (seq-remove
                                   (lambda (c)
                                     (and (not (plist-get c :children))
                                          (memq (plist-get c :status) verdict--hidden-statuses)))
                                   child-list)
                                child-list))
                  (init-failed (memq (plist-get node :status) '(error failed)))
                  (child-list (if (and output (or init-failed child-list))
                                  (cons (verdict--output-node id (plist-get node :label) output) child-list)
                                child-list)))
             (when child-list
               (let ((copy (copy-sequence node)))
                 (plist-put copy :children child-list)
                 copy))))
          ((and output (plist-member node :children)
                (memq (plist-get node :status) '(error failed)))
           (let ((copy (copy-sequence node)))
             (plist-put copy :children (list (verdict--output-node id (plist-get node :label) output)))
             copy))
          ((memq (plist-get node :status) verdict--hidden-statuses)
           nil)
          (t node))))
    ids)))

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
  :ret-action           #'verdict--visit
  :double-click-action  #'verdict--visit)

(treemacs-define-variadic-entry-node-type verdict-root
  :key        "verdict-root"
  :children   verdict-model
  :child-type 'verdict-node)

;;; Output Buffer

(defun verdict-output-back ()
  "Quit the verdict output buffer and return to the verdict buffer."
  (interactive)
  (quit-window nil (selected-window))
  (when-let* ((buf (get-buffer verdict-buffer-name)))
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
  (unless (derived-mode-p 'verdict-output-mode)
    (verdict-output-mode))
  (let (buffer-read-only)
    (erase-buffer)
    (let ((sep (propertize (make-string (length label) ?─) 'face 'verdict-name-face)))
      (insert sep "\n" (propertize label 'face 'verdict-name-face) "\n" sep "\n\n"))
    (when output
      (insert (ansi-color-apply (string-join (reverse output) "\n"))))))

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
      (when-let* ((win (display-buffer (current-buffer) '(display-buffer-below-selected))))
        (set-window-parameter win 'verdict-managed t)))))

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
  "Visit the file/line for the node whose link icon was clicked.
EVENT is the mouse event."
  (interactive "e")
  (when-let* ((pos (posn-point (event-start event))))
    (goto-char pos)
    (verdict--visit)))

(defun verdict--visit-link (file)
  "Return a propertized link icon string when FILE is non-nil."
  (when file
    (propertize " ↗" 'face 'verdict-button-face
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
                              (cons :tests file-tests))))
    (verdict--launch verdict--last-backend context nil)))

(defvar verdict--rerun-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'verdict--rerun-link-click)
    map)
  "Keymap for the rerun link icon in verdict nodes.")

(defun verdict--rerun-link-click (event)
  "Rerun the test/group whose rerun link was clicked.
EVENT is the mouse event."
  (interactive "e")
  (when-let* ((pos (posn-point (event-start event))))
    (goto-char pos)
    (verdict--rerun-at-node)))

(defvar verdict-results-map
  (let ((map (make-sparse-keymap)))
    (define-key map [tab]      #'verdict--toggle-or-show-output)
    (define-key map [?\t]      #'verdict--toggle-or-show-output)
    (define-key map [mouse-1]  #'verdict--single-click-action)
    (define-key map (kbd "r")  #'verdict--rerun-at-node)
    (define-key map (kbd "R")  #'verdict-run-last)
    (define-key map (kbd "!")  #'verdict-rerun-failed)
    (define-key map (kbd "k")  #'verdict-kill)
    map)
  "Keymap for the verdict results buffer.
Applied on top of the treemacs keymap.")

(defun verdict--rerun-link (item)
  "Return a propertized rerun link string for ITEM, or nil for output nodes."
  (unless (plist-get item :source-id)
    (propertize " ⟲" 'face 'verdict-button-face
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

(defun verdict--single-click-action (event)
  "Handle single click: move point, then toggle/show output.
Must be bound to a mouse click, or EVENT will not be supplied."
  (interactive "e")
  (when (eq 'mouse-1 (car event))
    (let ((start (event-start event)))
      (select-window (posn-window start))
      (goto-char (posn-point start)))
    (when (region-active-p)
      (keyboard-quit))
    (verdict--toggle-or-show-output)
    (treemacs--evade-image)))


;;; Node Helpers

(defun verdict--add-child (parent-id child-id)
  "Append CHILD-ID to the :children list of the node at PARENT-ID."
  (let* ((parent (gethash parent-id verdict--nodes))
         (updated-children (append (plist-get parent :children) (list child-id)))
         (updated-parent (plist-put parent :children updated-children)))
    (puthash parent-id updated-parent verdict--nodes)))

;;; Status Filter

(defun verdict--toggle-status-filter (status)
  "Toggle visibility of STATUS in the verdict tree and re-render.
Filter changes affect every group's visible child list, so this falls
back to a full render."
  (if (memq status verdict--hidden-statuses)
      (setq verdict--hidden-statuses (delq status verdict--hidden-statuses))
    (push status verdict--hidden-statuses))
  (verdict--render-full))

(defun verdict--render-command-header ()
  "Insert the run header at the top of the verdict buffer."
  (when verdict--run-header
    (let ((sep (propertize (make-string 40 ?─) 'face 'shadow)))
      (insert sep "\n")
      (insert (propertize verdict--run-header 'face 'shadow) "\n")
      (insert sep "\n"))))

(defun verdict--render-filter-header ()
  "Insert status filter buttons at the top of the verdict buffer.
Skips statuses whose count is zero, and omits the line entirely
when every count is zero."
  (let* ((counts (verdict--count-by-status))
         (any-nonzero (cl-some (lambda (e) (> (cdr e) 0)) counts)))
    (insert "\n")
    (when any-nonzero
      (insert "Show: ")
      (pcase-dolist (`(,status . ,count) counts)
        (when (> count 0)
          (let* ((hidden (memq status verdict--hidden-statuses))
                 (check  (if hidden "☐ " "☑ "))
                 (face   (if hidden 'shadow (verdict--status-face status)))
                 (label  (format "%s (%d)" status count))
                 (action (lambda (_btn) (verdict--toggle-status-filter status)))
                 (help   (format "Toggle %s tests" status)))
            (insert-text-button check
                                'face 'verdict-button-face
                                'action action
                                'follow-link t
                                'help-echo help)
            (insert-text-button label
                                'face `(:inherit (,face verdict-button-face))
                                'action action
                                'follow-link t
                                'help-echo help)
            (insert "  ")))))
    (insert "\n\n")))

;;; Render

(defvar verdict--mode-line-format)  ; defined below

(defun verdict--schedule-render ()
  "Schedule a render in 0.1 seconds, if one is not already pending."
  (unless verdict--render-timer
    (setq verdict--render-timer
          (run-with-timer 0.1 nil #'verdict--render))))

(defun verdict--ancestor-or-equal-p (ancestor descendant)
  "Non-nil if ANCESTOR is DESCENDANT or any ancestor of DESCENDANT."
  (let ((cur descendant))
    (while (and cur (not (equal ancestor cur)))
      (setq cur (verdict--parent-of cur)))
    cur))

(defun verdict--prune-dirty-ids (ids)
  "Drop ids in IDS that have an ancestor (or `:root') already in the set.
`:root' subsumes all other ids."
  (if (memq :root ids)
      '(:root)
    (cl-remove-if
     (lambda (id)
       (cl-some (lambda (other)
                  (and (not (eq other id))
                       (verdict--ancestor-or-equal-p other id)))
                ids))
     ids)))

(defun verdict--node-path (id)
  "Return the treemacs extension path list for ID."
  (let ((path (list id))
        (cur  (verdict--parent-of id)))
    (while cur
      (push cur path)
      (setq cur (verdict--parent-of cur)))
    (cons "verdict-root" path)))

(defun verdict--refresh-subtree-of (parent-id)
  "Refresh the children list of PARENT-ID via `treemacs-do-update-node'.
PARENT-ID is a node id; never `:root' (root refreshes go through the
full-render fallback because the variadic top-level button is
invisible and cannot be reached by `treemacs-find-visible-node').

Mutates the cached `:item.:children' on the parent button so that the
treemacs `:children' form sees freshly-built child plists when it
re-expands.  Builds the parent's full plist via `verdict--build-tree'
so synthetic `<init>' children and aggregate status are included."
  (-when-let* ((path (verdict--node-path parent-id))
               (dom  (treemacs-find-in-dom path))
               (btn  (treemacs-dom-node->position dom))
               (built (car (verdict--build-tree (list parent-id)))))
    (let ((stale-item (treemacs-button-get btn :item)))
      (plist-put stale-item :children (plist-get built :children)))
    (save-excursion
      (goto-char btn)
      (treemacs-do-update-node path))))

(defun verdict--render ()
  "Apply all pending dirty markers to the verdict buffer.
Refreshes only the dirtied subtrees via `treemacs-do-update-node', after
pruning ids whose ancestor is also dirty.  Falls back to
`verdict--render-full' when the dirty set reaches `:root' (the variadic
top-level button is invisible and cannot be reached by
`treemacs-find-visible-node')."
  (setq verdict--render-timer nil)
  (cond
   ((memq :root verdict--dirty-parent-ids)
    (setq verdict--dirty-parent-ids nil)
    (verdict--render-full))
   (verdict--dirty-parent-ids
    (let ((dirty (verdict--prune-dirty-ids
                  (delete-dups verdict--dirty-parent-ids))))
      (setq verdict--dirty-parent-ids nil)
      (when-let* ((buf (get-buffer verdict-buffer-name)))
        (with-current-buffer buf
          (treemacs-with-writable-buffer
           (dolist (id dirty)
             (verdict--refresh-subtree-of id)))
          (verdict--refresh-headers)
          (when (fboundp 'hl-line-highlight)
            (hl-line-highlight))))))))

(defun verdict--header-end ()
  "Return buffer position where the treemacs tree starts.
Skips the command and filter header region (`point-min' until the first
treemacs-managed button, i.e. the hidden variadic root marker).  The
filter header itself contains text-buttons (category `default-button'),
so we discriminate by category rather than the generic `button' property."
  (save-excursion
    (goto-char (point-min))
    (if-let* ((m (text-property-search-forward 'category 'treemacs-button t)))
        (prop-match-beginning m)
      (point-min))))

(defun verdict--render-headers ()
  "Insert command header and filter header at point.
Caller is responsible for being at `point-min' inside a writable buffer."
  (verdict--render-command-header)
  (verdict--render-filter-header))

(defun verdict--refresh-headers ()
  "Replace the header region (above the treemacs tree) with a freshly-built one."
  (treemacs-with-writable-buffer
   (save-excursion
     (let ((end (verdict--header-end)))
       (delete-region (point-min) end))
     (goto-char (point-min))
     (verdict--render-headers))))

(defun verdict--render-full ()
  "Erase and rebuild the entire verdict buffer.
This is the fallback path, used for initial setup, status-filter
toggles, `verdict-stop', and any event whose dirty marker reaches
`:root' (the variadic top-level button is invisible and cannot be
reached by `treemacs-find-visible-node').  Steady-state event flow
goes through `verdict--render' instead."
  (setq verdict--render-timer nil
        verdict--dirty-parent-ids nil)
  (setq verdict-model (verdict--build-tree verdict--root-ids))

  ;; Avoid accidental shadowing of treemacs-initialize by the deprecated treemacs-extensions
  (when (string-search "treemacs-extensions" (symbol-file 'treemacs-initialize 'defun))
    (load-library "treemacs-treelib"))

  (with-current-buffer (get-buffer-create verdict-buffer-name)
    (if (derived-mode-p 'treemacs-mode)
        (let ((saved-point (point))
              (saved-windows (mapcar (lambda (w) (cons w (window-start w)))
                                     (get-buffer-window-list (current-buffer) nil t))))
          (treemacs-with-writable-buffer
           (erase-buffer)
           (treemacs--render-extension (treemacs--ext-symbol-to-instance 'verdict-root) 99)
           (goto-char (point-min))
           (verdict--render-headers))
          (goto-char (min saved-point (point-max)))
          (dolist (entry saved-windows)
            (let ((w (car entry))
                  (ws (min (cdr entry) (point-max))))
              (set-window-start w ws t)))
          (when (fboundp 'hl-line-highlight)
            (hl-line-highlight)))
      (treemacs-initialize verdict-root :with-expand-depth 99)
      (treemacs-with-writable-buffer
       (goto-char (point-min))
       (verdict--render-headers))
      (setq-local mode-line-format verdict--mode-line-format)
      (let ((map (copy-keymap verdict-results-map)))
        (set-keymap-parent map (current-local-map))
        (use-local-map map)))
    (current-buffer)))

;;; Public API

;;;###autoload
(defun verdict-find-node (id)
  "Return the node plist for ID, or nil if no such node.
Backends that need to read state about a node (e.g. its file path,
for stack-trace linkification) should use this rather than reaching
into `verdict--nodes' directly.  The returned plist is shared with
internal state and must be treated as read-only by callers."
  (gethash id verdict--nodes))

;;;###autoload
(defun verdict-running-p ()
  "Return non-nil if a verdict run is currently in progress."
  (eq verdict--run-state 'running))

(defun verdict--spinner-tick ()
  "Advance spinner frame and patch in-tree spinner glyphs in place.
Avoids a full tree rebuild by walking text properties tagged
`verdict-spinner' and replacing each character with the new frame."
  (setq verdict--spinner-frame
        (mod (1+ verdict--spinner-frame) (length (verdict--spinner-frames))))
  (verdict--update-mode-line)
  (when-let* ((buf (get-buffer verdict-buffer-name)))
    (with-current-buffer buf
      (let ((new-frame (aref (verdict--spinner-frames) verdict--spinner-frame)))
        (treemacs-with-writable-buffer
         (save-excursion
           (goto-char (point-min))
           (let (m)
             (while (setq m (text-property-search-forward 'verdict-spinner t t))
               (let* ((start (prop-match-beginning m))
                      (end   (prop-match-end m))
                      (face  (get-text-property start 'face))
                      (disp  (get-text-property start 'display)))
                 (delete-region start end)
                 (goto-char start)
                 (insert (propertize new-frame
                                     'verdict-spinner t
                                     'face face
                                     'display disp)))))))))))

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
  (let* ((selected (if (fboundp 'mode-line-window-selected-p)
                       (mode-line-window-selected-p)
                     (eq (selected-window) (frame-selected-window))))
         (suffix (if selected "-mode-line-active-face" "-mode-line-face")))
    (intern (concat (string-remove-suffix "-face" (symbol-name face)) suffix))))

(defun verdict--count-by-status ()
  "Return an alist of (status . count) for all leaf nodes.
Reads from `verdict--status-counts', which is kept in sync by
`verdict-event' and `verdict-stop'."
  (copy-alist verdict--status-counts))

(defun verdict--mode-line-string ()
  "Return the mode line string for the verdict buffer."
  (pcase verdict--run-state
    ('running
     (let* ((spinner (aref (verdict--spinner-frames) verdict--spinner-frame))
            (base (verdict--mode-line-face 'verdict-running-face))
            (face (if verdict-icon-font
                      `(:inherit ,base :family ,verdict-icon-font)
                    base)))
       (concat " *verdict* " (propertize spinner 'face face) " Running… "
               (propertize "■ Stop"
                           'face (verdict--mode-line-face 'verdict-error-face)
                           'mouse-face 'highlight
                           'help-echo "Kill running tests"
                           'local-map (let ((map (make-sparse-keymap)))
                                        (define-key map [mode-line mouse-1]
                                          (lambda (_e) (interactive "e") (verdict-kill)))
                                        map)))))
    ('finished
     (let* ((counts (verdict--count-by-status))
            (count  (lambda (s) (or (cdr (assq s counts)) 0)))
            ;; (STATUS LABEL FACE).  Listed in display order; STATUS = nil means
            ;; the entry is always shown, otherwise it's only shown when count > 0.
            (rows '((stopped "stopped" verdict-stopped-face)
                    (skipped "skipped" verdict-skipped-face)
                    (error   "error"   verdict-error-face)
                    (failed  "failed"  verdict-error-face)
                    (passed  "passed"  verdict-success-face)))
            (parts nil)
            (total 0))
       (pcase-dolist (`(,status ,label ,face) rows)
         (let ((n (funcall count status)))
           (cl-incf total n)
           (when (or (> n 0) (eq status 'passed))
             (push (propertize (format "%d %s" n label)
                               'face (verdict--mode-line-face face))
                   parts))))
       (format " *verdict* %s — %d tests" (string-join parts ", ") total)))
    (_ " *verdict*")))

(defvar verdict--mode-line-format
  '(:eval (verdict--mode-line-string))
  "Mode line construct for the verdict buffer.")

(defun verdict--update-mode-line ()
  "Force a mode line update in the verdict buffer."
  (when-let* ((buf (get-buffer verdict-buffer-name)))
    (with-current-buffer buf
      (force-mode-line-update))))

(defun verdict--kill-output-buffer ()
  "Kill the *verdict-output* buffer and its verdict-managed window, if any."
  (when-let* ((buf (get-buffer "*verdict-output*")))
    (dolist (win (get-buffer-window-list buf nil t))
      (when (window-parameter win 'verdict-managed)
        (delete-window win)))
    (kill-buffer buf)))

(defun verdict-reset ()
  "Clear all internal verdict state.  Does not render."
  (verdict--kill-output-buffer)
  (verdict--spinner-stop)
  (clrhash verdict--nodes)
  (setq verdict--root-ids nil)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (setq verdict-model nil)
  (setq verdict--output-node-id nil)
  (setq verdict--run-state nil)
  (setq verdict--hidden-statuses nil)
  (setq verdict--status-counts nil)
  (setq verdict--dirty-parent-ids nil))

(defun verdict--maybe-save-buffer ()
  "Save the current buffer before a run, respecting `verdict-save-before-run'."
  (require 'cus-edit)  ; `customize-save-variable'
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

(defun verdict-start ()
  "Reset state and display the (empty) verdict buffer."
  (verdict--maybe-save-buffer)
  (verdict-reset)
  (setq verdict--run-state 'running)
  (verdict--spinner-start)
  (let ((buf (verdict--render-full)))
    (unless (get-buffer-window buf)
      (display-buffer buf '(nil (inhibit-same-window . t))))))

(defun verdict-stop ()
  "Mark all running nodes as stopped and render.
Uses the full-render path because every group's aggregate may have shifted."
  (verdict--spinner-stop)
  (setq verdict--run-state   'finished
        verdict--kill-handle nil)
  (when verdict--render-timer
    (cancel-timer verdict--render-timer)
    (setq verdict--render-timer nil))
  (maphash
   (lambda (id node)
     (when (eq (plist-get node :status) 'running)
       (puthash id (plist-put node :status 'stopped) verdict--nodes)
       (unless (plist-member node :children)
         (verdict--bump-status-count 'running -1)
         (verdict--bump-status-count 'stopped 1))))
   verdict--nodes)
  (verdict--render-full)
  (verdict--update-mode-line))

(defun verdict-event (event)
  "Process an EVENT plist and update internal state, then schedule a render.
EVENT must have a :type field with a keyword value.
A render is scheduled only when the event can change the visible
tree.  In particular, `:log' does not schedule a render unless it
adds a synthetic <init> output node (first log to a group node)."
  (when verdict-log-events
    (message "verdict: Received event %s" event))
  (pcase (plist-get event :type)
    (:group
     (let* ((id        (plist-get event :id))
            (parent-id (plist-get event :parent-id))
            (name      (plist-get event :name))
            (node      (list :id        id
                             :name      name
                             :label     (or (plist-get event :label) name)
                             :status    'running
                             :file      (plist-get event :file)
                             :line      (plist-get event :line)
                             :parent-id parent-id
                             :children  nil)))
       (puthash id node verdict--nodes)
       (if parent-id
           (verdict--add-child parent-id id)
         (setq verdict--root-ids (append verdict--root-ids (list id))))
       (verdict--mark-dirty-parent parent-id))
     (verdict--schedule-render))

    (:test-start
     (let* ((id        (plist-get event :id))
            (parent-id (plist-get event :parent-id))
            (name      (plist-get event :name))
            (node      (list :id        id
                             :name      name
                             :label     (or (plist-get event :label) name)
                             :status    'running
                             :file      (plist-get event :file)
                             :line      (plist-get event :line)
                             :parent-id parent-id)))
       (puthash id node verdict--nodes)
       (verdict--add-child parent-id id)
       (verdict--bump-status-count 'running 1)
       (verdict--mark-dirty-parent parent-id)
       (verdict--propagate-status-up id))
     (verdict--schedule-render))

    (:log
     (let* ((id     (plist-get event :id))
            (msg    (verdict--render-message (plist-get event :severity) (plist-get event :message)))
            (node   (gethash id verdict--nodes)))
       (when (and msg node)
         (let ((prev (plist-get node :output)))
           (plist-put node :output (cons msg prev))
           (verdict--append-output-buffer id prev msg)
           ;; Schedule a render only on the first log to a group node — that
           ;; is the one transition that can newly add a synthetic <init>
           ;; child to the tree.  Leaf logs and subsequent group logs never
           ;; change the tree.  Refreshing the group itself rebuilds its
           ;; :item.:children to include the new <init> entry.
           (when (and (null prev) (plist-member node :children))
             (verdict--mark-dirty-parent id)
             (verdict--schedule-render))))))

    (:test-done
     (when-let* ((id   (plist-get event :id))
                 (node (gethash id verdict--nodes)))
       (let ((prev (plist-get node :status))
             (new  (plist-get event :result)))
         (plist-put node :status new)
         (unless (plist-member node :children)
           (verdict--bump-status-count prev -1)
           (verdict--bump-status-count new 1))
         (verdict--mark-dirty-parent (verdict--parent-of id))
         (verdict--propagate-status-up id)
         (verdict--schedule-render))))

    (:done
     (setq verdict--run-state 'finished)
     (verdict--update-mode-line)
     (message "verdict: test run complete"))))

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
  "Handle PROC exit EVENT by flushing partial buffer and finalizing state."
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
  (when verdict--kill-handle
    (funcall verdict--kill-handle)
    (setq verdict--kill-handle nil))
  (setq verdict--partial "")
  (let* ((spec (funcall (plist-get backend :command-fn) context debug))
         (cmd  (plist-get spec :command))
         (dir  (or (plist-get spec :directory) default-directory))
         (default-directory dir))
    (setq verdict--run-header (plist-get spec :header))
    (verdict-start)
    (if (functionp cmd)
        (setq verdict--kill-handle (funcall cmd))
      (setq verdict--proc
            (make-process
             :name            "verdict"
             :command         cmd
             :connection-type 'pty
             :filter          #'verdict--filter
             :sentinel        #'verdict--sentinel
             :noquery         t))
      (setq verdict--kill-handle
            (lambda ()
              (when (process-live-p verdict--proc)
                (kill-process verdict--proc))))
      (message "verdict: running %s" (string-join cmd " "))
      (message "verdict: in %s" dir))))

(defun verdict--run (scope debug)
  "Run test SCOPE using the backend matching the current buffer.
DEBUG is passed to the backend's command function."
  (let* ((backend (verdict--active-backend))
         (context (funcall (plist-get backend :context-fn) scope)))
    (setq verdict--last-backend backend)
    (setq verdict--last-context context)
    (verdict--launch backend context debug)))

;;;###autoload
(defun verdict-kill ()
  "Kill the running test process or debug session."
  (interactive)
  (if verdict--kill-handle
      (let ((handle verdict--kill-handle))
        (setq verdict--kill-handle nil)
        (funcall handle))
    (user-error "No running verdict process")))

;;; Public Run Commands

;;;###autoload
(defun verdict-run-test-at-point ()
  "Run the test at point."
  (interactive) (verdict--run :test-at-point nil))
;;;###autoload
(defun verdict-run-group-at-point ()
  "Run the test group at point."
  (interactive) (verdict--run :group-at-point nil))
;;;###autoload
(defun verdict-run-file ()
  "Run the current file."
  (interactive) (verdict--run :file nil))
;;;###autoload
(defun verdict-run-module ()
  "Run the current module."
  (interactive) (verdict--run :module nil))
;;;###autoload
(defun verdict-run-project ()
  "Run the entire project."
  (interactive) (verdict--run :project nil))
;;;###autoload
(defun verdict-debug-test-at-point ()
  "Debug the test at point."
  (interactive) (verdict--run :test-at-point t))
;;;###autoload
(defun verdict-debug-group-at-point ()
  "Debug the test group at point."
  (interactive) (verdict--run :group-at-point t))
;;;###autoload
(defun verdict-debug-file ()
  "Debug the current file."
  (interactive) (verdict--run :file t))
;;;###autoload
(defun verdict-debug-module ()
  "Debug the current module."
  (interactive) (verdict--run :module t))
;;;###autoload
(defun verdict-debug-project ()
  "Debug the entire project."
  (interactive) (verdict--run :project t))

;;;###autoload
(defun verdict-run-last ()
  "Rerun the last test run."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (verdict--launch verdict--last-backend verdict--last-context nil))

;;;###autoload
(defun verdict-debug-last ()
  "Rerun the last test run with debugging."
  (interactive)
  (unless verdict--last-context (error "No previous verdict run to repeat"))
  (verdict--launch verdict--last-backend verdict--last-context t))

;;;###autoload
(defun verdict-rerun-failed ()
  "Rerun failed test cases from the last run."
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
                            (cons :tests file-tests))))
      (verdict--launch verdict--last-backend context nil))))


;;; Minor Mode

(defcustom verdict-keymap-prefix (kbd "C-c C-t")
  "Prefix key for `verdict-mode' keybindings.
Must be set before `verdict' is loaded; changing it afterwards has no
effect on the existing keymap."
  :type 'key-sequence
  :group 'verdict)

(defun verdict--make-keymap ()
  "Build the verdict minor-mode keymap using `verdict-keymap-prefix'."
  (let ((map (make-sparse-keymap))
        (prefix-map (make-sparse-keymap)))
    (define-key prefix-map "t" #'verdict-run-test-at-point)
    (define-key prefix-map "g" #'verdict-run-group-at-point)
    (define-key prefix-map "f" #'verdict-run-file)
    (define-key prefix-map "m" #'verdict-run-module)
    (define-key prefix-map "p" #'verdict-run-project)
    (define-key prefix-map "r" #'verdict-run-last)
    (define-key prefix-map "T" #'verdict-debug-test-at-point)
    (define-key prefix-map "G" #'verdict-debug-group-at-point)
    (define-key prefix-map "F" #'verdict-debug-file)
    (define-key prefix-map "M" #'verdict-debug-module)
    (define-key prefix-map "P" #'verdict-debug-project)
    (define-key prefix-map "R" #'verdict-debug-last)
    (define-key prefix-map "!" #'verdict-rerun-failed)
    (define-key prefix-map "k" #'verdict-kill)
    (define-key map verdict-keymap-prefix prefix-map)
    map))

(defvar verdict-mode-map (verdict--make-keymap)
  "Keymap for `verdict-mode'.")

;;;###autoload
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
