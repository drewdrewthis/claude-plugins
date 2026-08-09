# Changelog

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
