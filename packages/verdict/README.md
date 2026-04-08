# verdict

[![MELPA](https://melpa.org/packages/verdict-badge.svg)](https://melpa.org/#/verdict)
[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg)](https://github.com/RichardLitt/standard-readme)
[![Changelog](https://img.shields.io/badge/changelog-Keep%20a%20Changelog%20v1.1.0-%23E05735)](CHANGELOG.md)

Generic test runner for Emacs with a treemacs-based results UI.

Verdict provides a framework for running tests and displaying results in a
tree view. Language-specific backends plug in via a simple registration API.

![verdict demo](https://raw.githubusercontent.com/tjarvstrand/verdict.el/main/assets/verdict-demo.gif)

## Table of Contents

- [Available Backends](#available-backends)
- [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [API](#api)
- [Contributing](#contributing)
- [License](#license)

## Available Backends

- [verdict-dart](../../packages/verdict-dart/) — Dart and Flutter

## Install

### MELPA

```elisp
M-x package-install RET verdict RET
```

### use-package

```elisp
(use-package verdict)
```

## Usage

1. Install and configure a verdict backend (e.g. `verdict-dart`).
2. Run tests with the keybindings below.

By default, all commands are available under the `C-c t` prefix when
`verdict-mode` is active. This can be configured by setting
`verdict-keymap-prefix` before verdict is loaded.

| Key         | Command                         | Description               |
|-------------|---------------------------------|---------------------------|
| `C-c C-t t` | `verdict-run-test-at-point`    | Run test at point         |
| `C-c C-t g` | `verdict-run-group-at-point`   | Run enclosing group       |
| `C-c C-t f` | `verdict-run-file`             | Run current file          |
| `C-c C-t m` | `verdict-run-module`           | Run current module        |
| `C-c C-t p` | `verdict-run-project`          | Run all project tests     |
| `C-c C-t r` | `verdict-run-last`             | Rerun last test run       |
| `C-c C-t !` | `verdict-rerun-failed`         | Rerun only failed tests   |
| `C-c C-t k` | `verdict-kill`                 | Kill running test process |
| `C-c C-t T` | `verdict-debug-test-at-point`  | Debug test at point       |
| `C-c C-t G` | `verdict-debug-group-at-point` | Debug enclosing group     |
| `C-c C-t F` | `verdict-debug-file`           | Debug current file        |
| `C-c C-t M` | `verdict-debug-module`         | Debug current module      |
| `C-c C-t P` | `verdict-debug-project`        | Debug all project tests   |
| `C-c C-t R` | `verdict-debug-last`           | Debug last test run       |

In the results buffer:

| Key          | Action                                     |
|--------------|--------------------------------------------|
| **TAB**      | Expand/collapse group, or show test output  |
| **RET**      | Visit test file/line                        |
| **click**    | Expand/collapse group, or show test output  |
| **dbl-click**| Visit test file/line                        |
| `r`          | Rerun test/group at point                   |
| `R`          | Rerun last test run                         |
| `!`          | Rerun only failed tests                     |
| `k`          | Kill running test process                   |

## Configuration

| Variable                  | Default             | Description                                                   |
|---------------------------|---------------------|---------------------------------------------------------------|
| `verdict-keymap-prefix`   | `C-c C-t`           | Prefix key for all verdict keybindings (set before loading)   |
| `verdict-project-root-fn` | `project-current`   | Function to find the project root directory                   |
| `verdict-save-before-run` | `nil` (ask)         | Whether to save current buffer before run: `yes`, `no`, `nil` |
| `verdict-icon-font`       | auto-detected       | Font for status icons (Braille-capable preferred)             |
| `verdict-spinner-style`   | `braille` or `ascii`| Spinner animation style while tests run                       |
| `verdict-icon-height`     | `1.0`               | Relative height of status icons                               |
| `verdict-icon-passed`     | `✓`                 | Icon for passed tests                                         |
| `verdict-icon-failed`     | `✗`                 | Icon for failed tests                                         |
| `verdict-icon-error`      | `!`                 | Icon for errored tests                                        |
| `verdict-icon-skipped`    | `-`                 | Icon for skipped tests                                        |

## API

A verdict backend connects a language-specific test runner to the verdict UI.
To create one, you implement three functions and register them with
`verdict-register-backend`.

### Registration

```elisp
(verdict-register-backend PREDICATE CONTEXT-FN COMMAND-FN LINE-HANDLER)
```

**PREDICATE** determines when this backend is active. It can be:

- A **symbol** — a major-mode name; matched with `derived-mode-p`.
  Example: `'python-ts-mode`
- A **string** — a regexp; matched against `buffer-name`.
  Example: `"_test\\.py$"`
- A **function** — called with no arguments; non-nil means match.
  Example: `(lambda () (and (derived-mode-p 'python-ts-mode) (project-current)))`

The most recently registered backend takes precedence when multiple predicates
match.

### context-fn

```
(context-fn SCOPE) -> plist
```

Called in the user's source buffer (so `buffer-file-name`, `point`, etc. are
available). Returns a backend-specific context plist that will be passed to
`command-fn`.

**SCOPE** is one of:

- `:test-at-point` — run the test at point
- `:group-at-point` — run the group at point
- `:file` — run the current file
- `:module` — run the current module
- `:project` — run all project tests
- `(:tests . FILE-TESTS)` — rerun specific tests. `FILE-TESTS` is an alist of
  `(FILE . (NAME ...))` entries, provided when the user invokes
  `verdict-rerun-failed` or reruns a specific node.

The returned plist is opaque to verdict — it is passed through to `command-fn`
unchanged. Include whatever your backend needs (project root, file paths, test
names, etc.).

The context is reused when the user wants to run the same tests again.

### command-fn

```
(command-fn CONTEXT DEBUG) -> plist
```

Called with the context plist from `context-fn` and a boolean DEBUG flag.
Returns a plist with the following keys:

| Key          | Type                    | Required | Description                                                  |
|--------------|-------------------------|----------|--------------------------------------------------------------|
| `:command`   | list of strings **or** function | yes | Process arguments, or a function for custom launch           |
| `:directory` | string                  | yes      | Working directory for the process                            |
| `:name`      | string                  | yes      | Display name for the run                                     |
| `:header`    | string                  | no       | Header text shown at the top of the verdict buffer           |

When `:command` is a **list of strings**, it is used as the `:command` argument to `make-process`. Verdict will manage
the process (start, filter, sentinel).

When :command is a **function**, verdict calls it and the function is responsible for its own process management. The
function **must** call `verdict-stop` when the run is complete.

### line-handler

```
(line-handler LINE)
```

Called once per complete line of process output (newline-stripped). Parse the
line and call `verdict-event` with event plists to update the UI.

### Event API

Events are plists with a `:type` key. Call `verdict-event` with each event.

#### `:group`

Declares a test group (suite, describe block, etc.).

| Key          | Type           | Required | Description                        |
|--------------|----------------|----------|------------------------------------|
| `:type`      | `:group`       | yes      |                                    |
| `:id`        | any (unique)   | yes      | Globally unique identifier         |
| `:name`      | string         | yes      | Display name                       |
| `:label`     | string         | no       | Overrides `:name` for display      |
| `:file`      | string or nil  | no       | Absolute file path                 |
| `:line`      | integer or nil | no       | 1-based line number                |
| `:parent-id` | id or nil      | no       | Parent group ID                    |

If `:parent-id` references a non-existent node, the group becomes a root node.

#### `:test-start`

Declares and starts a test.

| Key          | Type           | Required | Description                        |
|--------------|----------------|----------|------------------------------------|
| `:type`      | `:test-start`  | yes      |                                    |
| `:id`        | any (unique)   | yes      | Globally unique identifier         |
| `:name`      | string         | yes      | Display name                       |
| `:label`     | string         | no       | Overrides `:name` for display      |
| `:file`      | string         | yes      | Absolute file path                 |
| `:line`      | integer        | yes      | 1-based line number                |
| `:parent-id` | id             | yes      | Parent group ID                    |

#### `:log`

Appends output to a node.

| Key          | Type                    | Required | Description                |
|--------------|-------------------------|----------|----------------------------|
| `:type`      | `:log`                  | yes      |                            |
| `:id`        | id (existing)           | yes      | Target node                |
| `:severity`  | `info` or `error`       | yes      | Controls face styling      |
| `:message`   | string                  | yes      | Log text                   |

`error` messages are displayed with `verdict-error-face`. `info` messages are
plain.

#### `:test-done`

Marks a test as finished.

| Key       | Type                                      | Required | Description     |
|-----------|-------------------------------------------|----------|-----------------|
| `:type`   | `:test-done`                              | yes      |                 |
| `:id`     | id (existing)                             | yes      | Target test     |
| `:result` | `passed`, `failed`, `error`, or `skipped` | yes      | Final status    |

#### `:done`

Signals the entire test run is complete. No additional keys.

```elisp
(verdict-event '(:type :done))
```

### Lifecycle

1. User triggers a run (e.g. `C-c C-t f`).
2. Verdict calls `context-fn` in the user's source buffer.
3. Verdict calls `command-fn` with the context.
4. Verdict starts the process (or calls the custom launcher).
5. Each output line is passed to `line-handler`.
6. `line-handler` calls `verdict-event` with parsed events.
7. The UI updates after each event.
8. The `:done` event finalizes the run.

### Example

A minimal backend skeleton:

```elisp
(defun my-backend-context (scope)
  (list :project (verdict--default-project-root)
        :file    (buffer-file-name)
        :scope   scope))

(defun my-backend-command (context _debug)
  (list :command   (list "my-test-runner" "--json" (plist-get context :file))
        :directory (plist-get context :project)
        :name      (file-name-nondirectory (plist-get context :file))))

(defun my-backend-line-handler (line)
  ;; Parse JSON, emit verdict events
  (when-let* ((data (ignore-errors (json-parse-string line :object-type 'plist))))
    (pcase (plist-get data :event)
      ("testStart"
       (verdict-event (list :type :test-start
                            :id   (plist-get data :id)
                            :name (plist-get data :name)
                            :file (plist-get data :file)
                            :line (plist-get data :line)
                            :parent-id (plist-get data :group))))
      ("testDone"
       (verdict-event (list :type   :test-done
                            :id     (plist-get data :id)
                            :result (intern (plist-get data :result)))))
      ("done"
       (verdict-event '(:type :done))))))

(verdict-register-backend 'my-test-mode
                          #'my-backend-context
                          #'my-backend-command
                          #'my-backend-line-handler)

(add-hook 'my-test-mode-hook #'verdict-mode)
```

### Node Model

- All node IDs must be globally unique within a run.
- Status transitions: `running` -> `passed` | `failed` | `error` | `skipped` | `stopped`.
- Groups have `:children` (list of child IDs). Leaf nodes (tests) do not.
- Only one test run can be active at a time.

## Contributing

PRs are welcome. Please open an issue first to discuss larger changes.

## License

GPL-3.0-or-later
