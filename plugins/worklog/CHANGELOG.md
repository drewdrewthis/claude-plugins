# Changelog

## [0.2.4](https://github.com/drewdrewthis/claude-plugins/compare/worklog-v0.2.3...worklog-v0.2.4) (2026-10-10)


### Bug Fixes

* **worklog:** stop old gitleaks from giving a silent raw result ([#249](https://github.com/drewdrewthis/claude-plugins/issues/249)) ([f2c5a3f](https://github.com/drewdrewthis/claude-plugins/commit/f2c5a3fe79c67c3b825be1ceed518aafc370295a))

## [0.2.3](https://github.com/drewdrewthis/claude-plugins/compare/worklog-v0.2.2...worklog-v0.2.3) (2026-10-10)


### Bug Fixes

* **worklog:** redact gitleaks-only tokens before punctuation ([#247](https://github.com/drewdrewthis/claude-plugins/issues/247)) ([84304ff](https://github.com/drewdrewthis/claude-plugins/commit/84304ff2b409d4fd308d3a91b557ea00ef825e20))

## [0.2.2](https://github.com/drewdrewthis/claude-plugins/compare/worklog-v0.2.1...worklog-v0.2.2) (2026-10-10)


### Bug Fixes

* **worklog:** keep valid uuids under load and add a differential redact fuzz test ([#236](https://github.com/drewdrewthis/claude-plugins/issues/236)) ([a0f9557](https://github.com/drewdrewthis/claude-plugins/commit/a0f95576f1718a739ee486544dd8a2582fa94c59))


### Documentation

* **worklog:** state the four accepted redact limits and pin each with a test ([#237](https://github.com/drewdrewthis/claude-plugins/issues/237)) ([14b595e](https://github.com/drewdrewthis/claude-plugins/commit/14b595e6520dd19771f56ee2c8c1740591571220))

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
