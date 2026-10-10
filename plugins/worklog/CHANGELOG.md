# Changelog

## [0.2.1](https://github.com/drewdrewthis/claude-plugins/compare/worklog-v0.2.0...worklog-v0.2.1) (2026-10-10)


### Bug Fixes

* **worklog,procedures:** keep the worklog judge out of the mistake intake, give mistake rows a session, keep channel quotes whole ([#235](https://github.com/drewdrewthis/claude-plugins/issues/235)) ([d4da805](https://github.com/drewdrewthis/claude-plugins/commit/d4da805be02db3b0038fbd0185c88e120d7ee260))
* **worklog:** note a missing gitleaks once per session and widen the built-in secret rules ([#213](https://github.com/drewdrewthis/claude-plugins/issues/213)) ([9353c1b](https://github.com/drewdrewthis/claude-plugins/commit/9353c1bfc77926cbe619f9c82ca8282532b86c58))
* **worklog:** redact glued tokens left raw after a marker and long AWS key runs ([#217](https://github.com/drewdrewthis/claude-plugins/issues/217)) ([0da91ef](https://github.com/drewdrewthis/claude-plugins/commit/0da91ef40956fb99b0b78da59d3cb2dfb8e809cf))
* **worklog:** redact secrets before writing the worklog ([#207](https://github.com/drewdrewthis/claude-plugins/issues/207)) ([9c16e07](https://github.com/drewdrewthis/claude-plugins/commit/9c16e0781b31822aaaa1778d31f4c17700ceee8b))
* **worklog:** redact tokens glued after another token ([#215](https://github.com/drewdrewthis/claude-plugins/issues/215)) ([05b2460](https://github.com/drewdrewthis/claude-plugins/commit/05b246073138548869adc73427eed69f980c9567))

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
