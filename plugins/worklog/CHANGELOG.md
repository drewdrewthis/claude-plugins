# Changelog

## [0.2.0](https://github.com/drewdrewthis/claude-plugins/compare/worklog-v0.1.0...worklog-v0.2.0) (2026-08-28)


### ⚠ BREAKING CHANGES

* **worklog:** procedures no longer ships the worklog-record Stop hook; install the worklog plugin to keep per-turn logging.

### Features

* **worklog:** extract the worklog Stop hook into its own plugin ([#138](https://github.com/drewdrewthis/claude-plugins/issues/138)) ([2c39512](https://github.com/drewdrewthis/claude-plugins/commit/2c395121e6f6228cb83d6cf79f655cc2d1c1003b))

## 0.1.0

Extracted from the procedures plugin (shipped there through procedures 0.11.0).
The worklog-record Stop hook, its bats suite, and vendored copies of
`lib/gate-failopen.sh` and `lib/gate-audience.sh` (the originals remain in
procedures, whose gates still use them).
