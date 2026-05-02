# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.1/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

 - Let custom launch functions return a kill-handle that can be used to stop the run.

### Changed

 - Skip the UI re-render on `:log` events that don't change the tree.
 - Animate running-test spinners by patching their glyphs in place instead of re-rendering the entire tree on every spinner tick.
 - Skip the hidden-status filter pass in `verdict--build-tree` when no statuses are hidden.
 - Accumulate per-node test output as a list of messages instead of repeatedly concatenating.
 - Cache leaf-status counts incrementally to avoid re-walking all nodes on each read.
 - Refresh only the affected subtree on per-event updates instead of erasing and re-rendering the entire buffer on every structural change.
 - Skip rendering when a `:test-done` event references an unknown node id.
 - Promote `verdict-buffer-name`, `verdict-log-events`, and `verdict-keymap-prefix` to `defcustom`.

### Fixed

 - Hidden statuses no longer distort the displayed aggregate of group nodes; the stored aggregate is used regardless of which child statuses are visible.

## [0.1.2] - 2026-04-13

### Fixed

 - Correct maintainer URL.
 - Remove dependency on s.
 - Required subr-x.
 - Declare treemacs use.
 - Use separate keymap for result buffer.
 - Check for derived major mode instead of major mode.
 - Fix buffer name when rerunning failed tests.

## [0.1.1] - 2026-04-08

### Added

 - Release script.
 - Added change logs

### Fixed

 - Changes to prepare for release on MELPA.
 - Update READMEs to adhere to the [standard-readme](https://github.com/RichardLitt/standard-readme) format.

## [0.1.0] - 2026-04-05

### Added

 - Initial release.

[Unreleased]: https://github.com/tjarvstrand/verdict/compare/verdict-v0.1.2...HEAD
[0.1.2]: https://github.com/tjarvstrand/verdict/compare/verdict-v0.1.1...verdict-v0.1.2
[0.1.1]: https://github.com/tjarvstrand/verdict/compare/verdict-v0.1.0...verdict-v0.1.1
[0.1.0]: https://github.com/tjarvstrand/verdict/releases/tag/verdict-v0.1.0
