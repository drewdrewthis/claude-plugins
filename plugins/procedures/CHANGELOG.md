# Changelog

## [0.5.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.4.1...procedures-v0.5.0) (2026-08-17)


### ⚠ BREAKING CHANGES

* **procedures:** the /log and /create-new slash commands no longer exist. Use /update-records <kind> for every knowledge artifact. Skill discovery is description-driven, so agents resolve the new command without changes; only a human typing the old slug is affected.

### Features

* **procedures:** GRC frame + replace /log and /create-new with /update-records ([#64](https://github.com/drewdrewthis/claude-plugins/issues/64)) ([da9d6f4](https://github.com/drewdrewthis/claude-plugins/commit/da9d6f4589a7123ed39a783db2f6cffb5b62821b))

## [0.4.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.4.0...procedures-v0.4.1) (2026-08-14)


### Bug Fixes

* **procedures:** gate messages resolve ([#28](https://github.com/drewdrewthis/claude-plugins/issues/28)), latent SIGPIPE ([#46](https://github.com/drewdrewthis/claude-plugins/issues/46)), scout repo resolution ([#48](https://github.com/drewdrewthis/claude-plugins/issues/48)) ([#50](https://github.com/drewdrewthis/claude-plugins/issues/50)) ([165ea0d](https://github.com/drewdrewthis/claude-plugins/commit/165ea0d54f08ecdcd75b8ba7eaa9bd65b77478ad))

## [0.4.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.3.1...procedures-v0.4.0) (2026-08-14)


### Features

* **procedures:** gate how-do-i on mutation + field-anchored mistakes.jsonl recall ([#39](https://github.com/drewdrewthis/claude-plugins/issues/39)) ([2e3b232](https://github.com/drewdrewthis/claude-plugins/commit/2e3b2321a909d6de9183b45b839b54c97817f47d))
* **procedures:** scout retrieval loop — batch fetch, warm digests, tier pin (closes [#34](https://github.com/drewdrewthis/claude-plugins/issues/34), [#24](https://github.com/drewdrewthis/claude-plugins/issues/24), [#22](https://github.com/drewdrewthis/claude-plugins/issues/22)) ([#45](https://github.com/drewdrewthis/claude-plugins/issues/45)) ([79c9af3](https://github.com/drewdrewthis/claude-plugins/commit/79c9af37e05e486e88f6584af18ad1da067d42e3))

## [0.3.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.3.0...procedures-v0.3.1) (2026-08-09)


### Bug Fixes

* **procedures:** traverse symlinked store dirs (find -H) ([#36](https://github.com/drewdrewthis/claude-plugins/issues/36)) ([f421166](https://github.com/drewdrewthis/claude-plugins/commit/f421166dd77bc2236de56a11fa8c8467937a810f))

## [0.3.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.2.3...procedures-v0.3.0) (2026-08-09)


### Features

* **procedures:** query the titw vendor store; byte-safe scans ([#33](https://github.com/drewdrewthis/claude-plugins/issues/33)) ([1d23fe2](https://github.com/drewdrewthis/claude-plugins/commit/1d23fe2e873d28a6390a713257c57f448392eac7))

## [0.2.3](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.2.2...procedures-v0.2.3) (2026-08-07)


### Bug Fixes

* **procedures:** bound the scout's search to the record stores ([#9](https://github.com/drewdrewthis/claude-plugins/issues/9)) ([4cb4071](https://github.com/drewdrewthis/claude-plugins/commit/4cb4071d2f4d507d3eee0d5cc04e72f8f3620150))
* **procedures:** bump to 0.2.2 to ship the gate-fork model pin ([#29](https://github.com/drewdrewthis/claude-plugins/issues/29)) ([6f737d4](https://github.com/drewdrewthis/claude-plugins/commit/6f737d47aebd637d81dc7303733c963670e2de9c))
* **procedures:** make a bad query loud, and bound the scout's toolset ([#23](https://github.com/drewdrewthis/claude-plugins/issues/23)) ([6327b8c](https://github.com/drewdrewthis/claude-plugins/commit/6327b8cbc356f38617b62b02dce31464fc49eab0))
* **procedures:** pin both gate forks to sonnet — a context:fork skill inherits the session model, not its agent's ([#25](https://github.com/drewdrewthis/claude-plugins/issues/25)) ([3bcddd5](https://github.com/drewdrewthis/claude-plugins/commit/3bcddd50a6e29a400573ddc7c1d391a6e65a68be))
* record namespaced skill invocations (gate wedge) ([cab1f2e](https://github.com/drewdrewthis/claude-plugins/commit/cab1f2e32cc2bbf09694f689674e1f2f9050f781))


### Performance

* **procedures:** 50x faster query-records, capped --full dump, scout batch-read flow + CodeRabbit config ([#5](https://github.com/drewdrewthis/claude-plugins/issues/5)) ([1135439](https://github.com/drewdrewthis/claude-plugins/commit/1135439f82338ead97207e6ece522837e99a381a))
