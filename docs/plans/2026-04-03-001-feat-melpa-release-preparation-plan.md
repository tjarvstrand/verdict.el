---
title: "feat: Prepare verdict and verdict-dart for MELPA release"
type: feat
status: active
date: 2026-04-03
---

# feat: Prepare verdict and verdict-dart for MELPA release

## Overview

Prepare the verdict test runner framework for public release as two separate MELPA packages: `verdict` (core framework) and `verdict-dart` (Dart/Flutter backend). This includes adding required package metadata, setting up CI, writing READMEs, creating a LICENSE, and drafting MELPA recipes.

## Problem Statement / Motivation

The verdict project is functional but not publishable. It lacks standard Emacs package headers, autoload cookies, a license file, CI, documentation, and MELPA recipes. Without these, users cannot discover or install it, and backend authors have no reference for implementing new runners.

## Proposed Solution

Complete all release prerequisites in a phased approach: restructure the repo by package, fix code issues, add metadata and packaging, then documentation, and finally submit to MELPA.

### Phase 0: Repository Restructure

Move from a flat layout to a `packages/` directory with one subdirectory per package. Each package gets its own README. The root `README.md` is a symlink to the verdict package README (since it's the primary package).

**Target layout:**
```
verdict.el/
├── LICENSE
├── README.md -> packages/verdict/README.md
├── mise.toml
├── .github/workflows/test.yml
├── packages/
│   ├── verdict/
│   │   ├── verdict.el
│   │   ├── verdict-demo.el
│   │   └── README.md          (core docs + backend author API)
│   ├── verdict-dart/
│   │   ├── verdict-dart.el
│   │   └── README.md          (dart-specific docs)
│   └── verdict-buttercup/
│       └── verdict-buttercup.el  (WIP, not published yet)
├── test/
│   ├── verdict-test.el
│   ├── verdict-dart-test.el
│   ├── fixtures/
│   └── resources/
└── docs/
    └── plans/
```

**Key decisions:**
- `test/` stays at the repo root — tests span packages and share fixtures.
- `verdict-demo.el` lives in `packages/verdict/` — it's a development aid for the core package.
- `verdict-buttercup.el` gets its own directory now for consistency, even though it's WIP.
- Root `README.md` symlinks to `packages/verdict/README.md` so GitHub shows the main docs. It includes links to sub-package READMEs (e.g., "See also: [verdict-dart](packages/verdict-dart/README.md)").
- `mise.toml` load paths (`-L .`) must be updated to `-L packages/verdict -L packages/verdict-dart` (or equivalent).

### Phase 1: Code Fixes & Metadata

**1.1 — Add LICENSE file**
- Create `LICENSE` at repo root with GPL-3.0-or-later text.
- MELPA requires a GPL-compatible license. This is a submission blocker.

**1.2 — Add `defgroup` declarations**

`verdict.el`:
```elisp
(defgroup verdict nil
  "Generic test runner with treemacs results UI."
  :group 'tools
  :prefix "verdict-")
```

`verdict-dart.el`:
```elisp
(defgroup verdict-dart nil
  "Dart backend for verdict."
  :group 'verdict
  :prefix "verdict-dart-")
```

Ensure all existing `defcustom` forms reference the correct group. `verdict-dart-debug-fn` currently has no `:group` — add `:group 'verdict-dart`.

**1.3 — Complete file headers**

Both `verdict.el` and `verdict-dart.el` need:
- `Author:` / `Maintainer:` — Thomas Jarvstrand
- `Version:` — `0.1.0`
- `URL:` — `https://github.com/tjarvstrand/verdict.el`
- `Keywords:` — `tools, processes` (verdict), `tools, languages` (verdict-dart)
- `;;; Commentary:` section (MELPA extracts description from here)
- `;;; Code:` section marker
- License boilerplate above Commentary

**1.4 — Fix undeclared `yaml` dependency in verdict-dart.el**

`verdict-dart.el` does `(require 'yaml)` but does not declare it in `Package-Requires`. Update to:
```elisp
;; Package-Requires: ((emacs "30.0") (verdict "0.1") (f "0.20") (yaml "0.5"))
```

**1.5 — Add autoload cookies**

In `verdict.el`, add `;;;###autoload` to:
- `verdict-mode` (minor mode definition)
- All `verdict-run-*` and `verdict-debug-*` interactive commands
- `verdict-run-last`, `verdict-debug-last`, `verdict-rerun-failed`, `verdict-kill`
- `verdict-register-backend` (so backends can register without fully loading verdict)

In `verdict-dart.el`, decide on autoload strategy (see Technical Considerations below).

**1.6 — Fix `verdict-dart--url-to-file` nil crash**

Line 174 of `verdict-dart.el`: `string-remove-prefix` will error on nil input despite the docstring claiming nil-safety. Wrap in `(when url ...)`.

**1.7 — Lower minimum Emacs version to 29.1**

Investigation results:
- `mode-line-window-selected-p` (verdict.el:674) is the **only** 30.x feature used in either file. Introduced in Emacs 30.1.
- `treesit` (verdict-dart.el) requires 29.1+ but that's only the dart backend.
- `treemacs-treelib` (used by verdict.el) is a treemacs v3.0 feature with no Emacs version gate — works on 29.1.
- All other features (`seq-*`, `when-let*`, `string-search`, `read-answer`) are available in 28.1 or earlier.

**Action:** Replace the `mode-line-window-selected-p` call with a compatibility shim:
```elisp
(if (fboundp 'mode-line-window-selected-p)
    (mode-line-window-selected-p)
  (eq (selected-window) (frame-selected-window)))
```

Update `Package-Requires` in both files to `(emacs "29.1")`.

Also bump treemacs dependency from `"2.0"` to `"3.0"` — the treelib API was introduced in treemacs v3.0.

### Phase 2: CI Pipeline

**2.1 — Add mise tasks for byte-compile and package-lint**

The existing `mise.toml` already has `deps`, `test`, `test:verdict`, and `test:verdict-dart` tasks. Add:

```toml
[tasks.lint]
description = "Run package-lint on all package files"
depends = ["deps"]
run = """
emacs -batch \
  --eval '(setq package-user-dir (expand-file-name ".packages" default-directory))' \
  --eval '(package-initialize)' \
  --eval '(unless (package-installed-p (quote package-lint)) (package-install (quote package-lint)))' \
  --eval '(require (quote package-lint))' \
  --eval '(setq package-lint-main-file "packages/verdict/verdict.el")' \
  -f package-lint-batch-and-exit \
  packages/verdict/verdict.el packages/verdict-dart/verdict-dart.el
"""

[tasks.compile]
description = "Byte-compile all package files"
depends = ["deps"]
run = """
emacs -batch \
  --eval '(setq package-user-dir (expand-file-name ".packages" default-directory))' \
  --eval '(package-initialize)' \
  -L packages/verdict \
  -L packages/verdict-dart \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile \
  packages/verdict/verdict.el packages/verdict-dart/verdict-dart.el
"""

[tasks.ci]
description = "Run all CI checks (compile, lint, test)"
depends = ["compile", "lint", "test"]
```

Also update the existing `deps` task to install `package-lint`, and update all existing test tasks to use `-L packages/verdict -L packages/verdict-dart` instead of `-L .`.

**2.2 — GitHub Actions workflow** (`.github/workflows/test.yml`)

The workflow installs mise and delegates to the same tasks developers run locally:

```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore: ['**.md']
  pull_request:
    paths-ignore: ['**.md']

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        emacs-version:
          - 29.1
          - 30.1
          - snapshot

    steps:
      - uses: actions/checkout@v4

      - uses: purcell/setup-emacs@master
        with:
          version: ${{ matrix.emacs-version }}

      - uses: jdx/mise-action@v2

      - name: Install dependencies
        run: mise run deps

      - name: Byte-compile
        run: mise run compile

      - name: Lint
        run: mise run lint

      - name: Test
        run: mise run test
```

The matrix tests 29.1 (minimum supported), 30.1 (latest stable), and snapshot.

**Note on dart tests:** The `test/fixtures/*.jsonl` files must be committed to the repo so CI does not need the Dart SDK. Verify these are already tracked in git.

### Phase 3: Documentation

**3.1 — `packages/verdict/README.md` (symlinked to root `README.md`)**

This is the main project README, shown on GitHub via symlink. Include a short "Related packages" section at the top or bottom linking to sub-package READMEs (e.g., "[verdict-dart](packages/verdict-dart/README.md) — Dart/Flutter backend").

Sections:
1. **Header** — Name, one-line description, MELPA badge (`[![MELPA](https://melpa.org/packages/verdict-badge.svg)](https://melpa.org/#/verdict)`)
2. **Screenshot/GIF** — Treemacs UI showing test results (optional but highly recommended)
3. **Installation** — MELPA (`M-x package-install RET verdict`), use-package, manual
4. **Quick Start** — Enable `verdict-mode`, run tests with keybindings
5. **Commands** — Table of all interactive commands with default keybindings
6. **Configuration** — All `defcustom` variables with descriptions
7. **Writing a Backend** — The full backend author guide (see below)
8. **Available Backends** — Links to verdict-dart (and verdict-buttercup when ready)

**Backend Author API Reference** (critical section):

Must document:

- **`verdict-register-backend`** — Full signature: `(predicate context-fn command-fn line-handler)`
  - Predicate forms: major-mode symbol (matched via `derived-mode-p`), regexp string (matched against `buffer-name`), or function (called with no args)
  - `context-fn`: `(scope &optional file-tests)` → returns backend-specific context plist
    - `scope` values: `:at-point`, `:group`, `:file`, `:module`, `:project`
    - `file-tests` (optional): alist of `(FILE . (NAME ...))` entries, used for `verdict-rerun-failed` and node reruns
  - `command-fn`: `(context debug)` → returns plist `(:command CMD :directory DIR :name NAME :header HEADER)`
    - `:command` is a list of strings (process args) or a function (custom launcher that must call `verdict-stop` when done)
    - `:directory` is the working directory
    - `:name` is a display name for the run
    - `:header` is an optional header string shown in the results buffer
  - `line-handler`: `(line)` → called once per output line; should call `verdict-event` with event plists

- **Event API** — All event types with required/optional plist keys and value types:
  - `:group` — `:id` (unique), `:name` (string), `:file` (string path or nil), `:line` (integer or nil), `:parent-id` (id or nil), `:file-id` (id or nil)
  - `:test-start` — `:id` (unique), `:name` (string), `:file` (string path), `:line` (integer), `:group-ids` (list of ids), `:file-id` (id)
  - `:log` — `:id` (existing id), `:severity` (`:info` or `:error`), `:message` (string)
  - `:test-done` — `:id` (existing id), `:result` (`passed`, `failed`, `error`, `skipped`)
  - `:done` — (no additional keys)

- **Node data model** — ID uniqueness requirement, status symbols, parent-child relationships
- **Lifecycle** — Backend registration → user triggers run → `context-fn` called in user's buffer → `command-fn` called → process started → `line-handler` receives output → events update UI → `:done` event finalizes

**3.2 — `packages/verdict-dart/README.md`**

Separate README for the dart backend. Dart users navigate here from the link in the main README or find it browsing the repo.

Sections:
1. **Installation** — `M-x package-install RET verdict-dart` (auto-installs verdict)
2. **Setup** — How to enable (require or autoload pattern)
3. **Usage** — Keybindings in `dart-ts-mode`, running tests, viewing output
4. **Flutter support** — How Flutter projects are detected (`verdict-dart-flutter-packages`)
5. **Debug integration** — How `dape` integration works, `verdict-dart-debug-fn`
6. **Configuration** — `defcustom` variables

### Phase 4: MELPA Submission

**4.1 — Run `package-lint` and `checkdoc` locally**

Fix all warnings before submission. `melpazoid` (MELPA's CI) runs these automatically on recipe PRs.

**4.2 — Draft MELPA recipes**

```elisp
;; recipes/verdict
(verdict
 :fetcher github
 :repo "tjarvstrand/verdict.el"
 :files ("packages/verdict/verdict.el"))
```

```elisp
;; recipes/verdict-dart
(verdict-dart
 :fetcher github
 :repo "tjarvstrand/verdict.el"
 :files ("packages/verdict-dart/verdict-dart.el"))
```

The `:files` lists point into the package subdirectories. This cleanly excludes verdict-buttercup (WIP), verdict-demo.el, and test files without needing `:exclude` rules.

**4.3 — Submission order**

1. Submit `verdict` recipe PR to `melpa/melpa` first
2. Wait for it to be merged and the package to appear on MELPA
3. Then submit `verdict-dart` recipe PR (its `Package-Requires` declares `(verdict "0.1")`)

MELPA requires one recipe per PR and will reject if the dependency is not yet available.

## Technical Considerations

### verdict-dart autoload / auto-registration strategy

**Current behavior:** Loading `verdict-dart.el` immediately calls `verdict-register-backend` and `add-hook` for `dart-ts-mode-hook`. This means `(require 'verdict-dart)` in the user's init file is sufficient.

**Options:**

| Option | Pros | Cons |
|---|---|---|
| Keep auto-register (current) | Simple for users: just `(require 'verdict-dart)` | Loading has side effects; unconventional |
| `with-eval-after-load` autoload | Registers when verdict loads; no manual require needed | More magic; harder to debug |
| Explicit setup function | Matches verdict-buttercup pattern; predictable | Extra step for users |

Recommend documenting the current auto-register behavior clearly in the README. It is the simplest for end users and works well for a single-backend scenario.

### verdict-demo.el disposition

Lives in `packages/verdict/` alongside `verdict.el` but is excluded from the MELPA recipe (`:files` only lists `verdict.el`). It's a development aid for contributors.

### Single test run limitation

All verdict state is global — only one test run can exist at a time. This is by design but should be documented in the README to set expectations.

### `dash` transitive dependency in verdict-dart

`verdict-dart.el` uses `-->` from `dash` but does not declare it in `Package-Requires` (it comes transitively via `verdict`). Add `dash` to verdict-dart's `Package-Requires` — MELPA reviewers will flag direct usage of an undeclared dependency, and being explicit costs nothing.

## Acceptance Criteria

- [x] Repo restructured: `packages/verdict/`, `packages/verdict-dart/`, `packages/verdict-buttercup/` with `.el` files moved
- [x] Root `README.md` symlinked to `packages/verdict/README.md`
- [x] `mise.toml` and test load paths updated for new directory structure
- [x] `LICENSE` file (GPL-3.0-or-later) exists at repo root
- [x] `defgroup` defined in both `verdict.el` and `verdict-dart.el`
- [x] Complete file headers (Author, Maintainer, Version, URL, Keywords, Commentary, license boilerplate) in both files
- [x] `yaml` and `dash` declared in `verdict-dart.el` Package-Requires
- [x] `;;;###autoload` cookies on all public interactive commands and `verdict-mode`
- [x] `verdict-dart--url-to-file` handles nil input safely
- [x] Emacs minimum version lowered to 29.1 (shim `mode-line-window-selected-p`, bump treemacs to 3.0)
- [x] `.github/workflows/test.yml` runs byte-compile, package-lint, and buttercup tests
- [ ] CI passes on push to main and on PRs
- [x] `README.md` includes installation, usage, commands, configuration, and full backend author API reference with data types
- [x] verdict-dart documentation includes installation, setup, usage, Flutter support, and debug integration
- [ ] `package-lint` and `checkdoc` produce zero warnings on both files
- [ ] MELPA recipes drafted with correct `:files` lists
- [ ] `verdict` recipe PR submitted to melpa/melpa
- [ ] `verdict-dart` recipe PR submitted after `verdict` is merged

## Success Metrics

- Both packages installable from MELPA with `M-x package-install`
- CI green on all supported Emacs versions
- A third-party developer can implement a new backend using only the README (no source reading required)
- `package-lint` and `checkdoc` clean

## Dependencies & Risks

| Risk | Impact | Mitigation |
|---|---|---|
| MELPA review may request changes | Delays publication | Run `package-lint`, `checkdoc`, and `melpazoid` locally before submitting |
| MELPA may reject two packages from one repo | Forces repo split | Precedent exists (magit/magit-section); use explicit `:files` |
| Emacs 29.1 compatibility shim | Minor maintenance | Only one shim needed (`mode-line-window-selected-p`); can be removed when 29.x is EOL |
| `byte-compile-error-on-warn` may surface issues | CI failures | Fix warnings incrementally; `dape` soft-dependency may need `declare-function` |
| verdict-buttercup.el accidentally packaged | Wrong files in MELPA | Lives in its own `packages/verdict-buttercup/` dir; MELPA recipes only reference their own subdirectory |

## Sources & References

- [MELPA Contributing Guide](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org) — submission requirements, recipe format
- [MELPA recipes/magit](https://github.com/melpa/melpa/blob/master/recipes/magit) — multi-package repo precedent
- [purcell/setup-emacs](https://github.com/purcell/setup-emacs) — GitHub Action for Emacs CI
- [package-lint](https://github.com/purcell/package-lint) — MELPA header/convention checker
- [Emacs Package Developer's Handbook](https://alphapapa.github.io/emacs-package-dev-handbook/) — packaging best practices
- Similar files: `verdict.el:1-10` (current headers), `verdict-dart.el:1-10` (current headers)
