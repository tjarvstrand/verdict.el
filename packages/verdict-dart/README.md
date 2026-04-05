# verdict-dart

[![MELPA](https://melpa.org/packages/verdict-dart-badge.svg)](https://melpa.org/#/verdict-dart)

Dart and Flutter test backend for [verdict](../../packages/verdict/).

Runs `dart test` or `flutter test` and displays results in verdict's treemacs
UI. Supports test discovery via tree-sitter and debug sessions via dape.

## Requirements

- Emacs 29.1+
- Dart SDK or Flutter SDK on `PATH`
- [tree-sitter](https://github.com/tree-sitter/tree-sitter)
- A dart tree-sitter grammar


## Installation

### Grammar

```elisp
(add-to-list
 'treesit-language-source-alist
 '(dart "https://github.com/UserNobody14/tree-sitter-dart"))

(unless (treesit-language-available-p 'dart)
  (treesit-install-language-grammar 'dart))
```

### verdict-dart

```elisp
M-x package-install RET verdict-dart RET
```

Or, with `use-package`:

```elisp
(use-package verdict-dart)
```

## Setup

```elisp
(add-hook 'dart-ts-mode-hook #'verdict-mode)
```

Or with `dart-mode`:

```elisp
(add-hook 'dart-mode-hook #'verdict-mode)
```

## Usage

With a Dart test file open:

| Key       | Action                            |
|-----------|-----------------------------------|
| `C-c C-t t` | Run test at point                 |
| `C-c C-t g` | Run enclosing group               |
| `C-c C-t f` | Run current file                  |
| `C-c C-t p` | Run all project tests             |
| `C-c C-t r` | Rerun last test run               |
| `C-c C-t !` | Rerun only failed tests           |
| `C-c C-t k` | Kill running test process         |
| `C-c C-t T` | Debug test at point               |
| `C-c C-t F` | Debug current file                |

Results appear in the `*verdict*` buffer. Press **RET** on a test node to jump
to its source location. Failed tests show their output in `*verdict-output*`.

## Flutter Support

verdict-dart detects Flutter projects automatically. If a test file imports any
package listed in `verdict-dart-flutter-packages` (default: `("flutter_test")`),
`flutter test` is used instead of `dart test`.

## Debug Integration

Debug commands (`C-c C-t T`, etc.) by default use [dape](https://github.com/svaante/dape) if it is installed.

```elisp
(use-package dape)
```

To use a different debugger, set `verdict-dart-debug-fn` to a function that
accepts a context plist with keys `:project`, `:files`, `:names`, `:name`,
`:runner` (either `"dart"` or `"flutter"`).

## Configuration

| Variable                       | Default                          | Description                          |
|--------------------------------|----------------------------------|--------------------------------------|
| `verdict-dart-debug-fn`        | uses dape if available           | Function to launch debug sessions    |
| `verdict-dart-flutter-packages`| `("flutter_test")`               | Package imports that trigger `flutter test` |

## License

GPL-3.0-or-later
