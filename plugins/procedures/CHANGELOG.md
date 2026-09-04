# Changelog

## [0.15.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.14.1...procedures-v0.15.0) (2026-09-04)


### ⚠ BREAKING CHANGES

* drop ~/.claude fallback root — knowledge must live in ~/.knowledge modules ([#161](https://github.com/drewdrewthis/claude-plugins/issues/161))

### Features

* drop ~/.claude fallback root — knowledge must live in ~/.knowledge modules ([#161](https://github.com/drewdrewthis/claude-plugins/issues/161)) ([7f51912](https://github.com/drewdrewthis/claude-plugins/commit/7f51912a1b4ecab6401bdd65f9e70a6a35c8e84f))

## [0.14.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.14.0...procedures-v0.14.1) (2026-09-04)


### Bug Fixes

* require bash 4+ for declare -A scripts, re-exec on macOS 3.2 ([#156](https://github.com/drewdrewthis/claude-plugins/issues/156)) ([7c2a6b8](https://github.com/drewdrewthis/claude-plugins/commit/7c2a6b8480355c2faa8bf2f91ecedc49c27d4015))

## [0.14.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.13.3...procedures-v0.14.0) (2026-09-03)


### Features

* **procedures:** ~/.knowledge home — module auto-discovery, config.json, state dir ([#154](https://github.com/drewdrewthis/claude-plugins/issues/154)) ([a0a028e](https://github.com/drewdrewthis/claude-plugins/commit/a0a028e209fb600adc3e61b75ca95db11f729152))

## [0.13.3](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.13.2...procedures-v0.13.3) (2026-09-03)


### Bug Fixes

* **procedures:** settings.json store roots outrank legacy CODEX_ROOT ([#151](https://github.com/drewdrewthis/claude-plugins/issues/151)) ([3f8c059](https://github.com/drewdrewthis/claude-plugins/commit/3f8c059e020055f37e9e13ef5fa0e310ce7f08c6))

## [0.13.2](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.13.1...procedures-v0.13.2) (2026-09-03)


### Bug Fixes

* fall back to settings.json for CODEX_STORE_ROOTS when env unset ([#149](https://github.com/drewdrewthis/claude-plugins/issues/149)) ([5299eb9](https://github.com/drewdrewthis/claude-plugins/commit/5299eb99f5f7af2e2524061584cda6066b077dc3))

## [0.13.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.13.0...procedures-v0.13.1) (2026-09-02)


### Bug Fixes

* **procedures:** invalidate the how-do-i index cache on roots/record changes ([#147](https://github.com/drewdrewthis/claude-plugins/issues/147)) ([4bb9bbf](https://github.com/drewdrewthis/claude-plugins/commit/4bb9bbfc5ee0ac37351827ece87b2b2936b30911))

## [0.13.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.12.0...procedures-v0.13.0) (2026-09-01)


### ⚠ BREAKING CHANGES

* **procedures:** soft gates by default; what-do-i-know + adherence-check skills ([#144](https://github.com/drewdrewthis/claude-plugins/issues/144))

### Features

* **procedures:** librarian single-writer intake + multi-root index ([#145](https://github.com/drewdrewthis/claude-plugins/issues/145)) ([586be3b](https://github.com/drewdrewthis/claude-plugins/commit/586be3b8e1d4f7687a8ee2c0195759cac56f599e))
* **procedures:** soft gates by default; what-do-i-know + adherence-check skills ([#144](https://github.com/drewdrewthis/claude-plugins/issues/144)) ([82eb2e5](https://github.com/drewdrewthis/claude-plugins/commit/82eb2e558c55b794d6aca88ed495dca686185741))

## [0.12.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.11.0...procedures-v0.12.0) (2026-08-28)


### ⚠ BREAKING CHANGES

* **worklog:** procedures no longer ships the worklog-record Stop hook; install the worklog plugin to keep per-turn logging.

### Features

* **worklog:** extract the worklog Stop hook into its own plugin ([#138](https://github.com/drewdrewthis/claude-plugins/issues/138)) ([2c39512](https://github.com/drewdrewthis/claude-plugins/commit/2c395121e6f6228cb83d6cf79f655cc2d1c1003b))


### Bug Fixes

* **procedures:** treat an empty how-do-i selection as an answer, not a failure ([#142](https://github.com/drewdrewthis/claude-plugins/issues/142)) ([0d72b78](https://github.com/drewdrewthis/claude-plugins/commit/0d72b7848d0f10091cb1e7e8bbf6c3f36844cf69))

## [0.11.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.10.0...procedures-v0.11.0) (2026-08-27)


### Features

* **procedures:** worklog-record Stop hook — one JSONL line per turn ([#95](https://github.com/drewdrewthis/claude-plugins/issues/95)) ([d7c1342](https://github.com/drewdrewthis/claude-plugins/commit/d7c1342dfe6caae2f8ef8af8fca7b2a59247996a))
* **worklog:** record the turn as requests/outcomes/mistakes with per-entry evidence ([#104](https://github.com/drewdrewthis/claude-plugins/issues/104)) ([1f4ff06](https://github.com/drewdrewthis/claude-plugins/commit/1f4ff069c4f8a1a26e9e498434279109c3f22982))


### Bug Fixes

* **procedures:** run how-do-i inline and remove the orphaned procedure-scout agent ([#135](https://github.com/drewdrewthis/claude-plugins/issues/135)) ([88ea6f3](https://github.com/drewdrewthis/claude-plugins/commit/88ea6f36435ecc3d6e037a3752f55fc93da952e6))
* **procedures:** run how-do-i inline to end the session-budget fork wedge ([#135](https://github.com/drewdrewthis/claude-plugins/issues/135)) ([#137](https://github.com/drewdrewthis/claude-plugins/issues/137)) ([88ea6f3](https://github.com/drewdrewthis/claude-plugins/commit/88ea6f36435ecc3d6e037a3752f55fc93da952e6))

## [0.10.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.9.1...procedures-v0.10.0) (2026-08-25)


### ⚠ BREAKING CHANGES

* **procedures:** fire record evolution from an evolve-sweep Stop hook, not from /am-i-done ([#132](https://github.com/drewdrewthis/claude-plugins/issues/132))

### Features

* **procedures:** fire record evolution from an evolve-sweep Stop hook, not from /am-i-done ([#132](https://github.com/drewdrewthis/claude-plugins/issues/132)) ([8b7d3bf](https://github.com/drewdrewthis/claude-plugins/commit/8b7d3bf4495f1f1fd7e81db96b6046e3079207c3))

## [0.9.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.9.0...procedures-v0.9.1) (2026-08-24)


### Bug Fixes

* **procedures:** make the orwrap gateway fallback actually take effect ([#126](https://github.com/drewdrewthis/claude-plugins/issues/126)) ([86b57f2](https://github.com/drewdrewthis/claude-plugins/commit/86b57f2c0fd48a3153e7be3577e2aafd5d30dd68))

## [0.9.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.8.1...procedures-v0.9.0) (2026-08-24)


### Features

* **procedures:** cut how-do-i over to the index pipeline; drop query-records ([#124](https://github.com/drewdrewthis/claude-plugins/issues/124)) ([6ef760c](https://github.com/drewdrewthis/claude-plugins/commit/6ef760c0d661c84e57cd32174e48191a0987aebe))

## [0.8.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.8.0...procedures-v0.8.1) (2026-08-24)


### Bug Fixes

* **procedures:** how-do-i gateway compat + harness token cut ([#122](https://github.com/drewdrewthis/claude-plugins/issues/122)) ([2f85dde](https://github.com/drewdrewthis/claude-plugins/commit/2f85dde1848bc3a68ae5d08cdf6f89dd92300cd8))
* **procedures:** how-do-i works through gateways and cuts harness token cost ([2f85dde](https://github.com/drewdrewthis/claude-plugins/commit/2f85dde1848bc3a68ae5d08cdf6f89dd92300cd8))

## [0.8.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.7.1...procedures-v0.8.0) (2026-08-24)


### Features

* **procedures:** indexed two-stage retrieval for how-do-i, description as retrieval surface ([#112](https://github.com/drewdrewthis/claude-plugins/issues/112)) ([217112e](https://github.com/drewdrewthis/claude-plugins/commit/217112e123de9d4305e506860c885a7d3c7d3556))

## [0.7.1](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.7.0...procedures-v0.7.1) (2026-08-20)


### Bug Fixes

* **procedures:** allowlist WebFetch/WebSearch in the how-do-i gate ([25cdbb1](https://github.com/drewdrewthis/claude-plugins/commit/25cdbb15482f471c06c683b244aaee40f0f82ff8))
* **procedures:** allowlist WebFetch/WebSearch in the how-do-i gate ([f35c987](https://github.com/drewdrewthis/claude-plugins/commit/f35c987f73ad34ce49b05d96723034c91f74fc94))
* **procedures:** review fixes — Edit -eq 1 coverage, hook status assert, honest comments ([6d5552c](https://github.com/drewdrewthis/claude-plugins/commit/6d5552c2717d5d41cd562a0658d75b31871d4ce5))

## [0.7.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.6.0...procedures-v0.7.0) (2026-08-18)


### Features

* **procedures:** --project filter over the record project: key ([752b798](https://github.com/drewdrewthis/claude-plugins/commit/752b7988fb1e5b2696f71bdb242e39bfb51d176b))
* **procedures:** --project filter over the record project: key ([2f33e5e](https://github.com/drewdrewthis/claude-plugins/commit/2f33e5e667c090aebd95bed0e4a5e787c3e07539))
* **procedures:** one off-switch per gate, on by default, recorded when used ([4c8552a](https://github.com/drewdrewthis/claude-plugins/commit/4c8552a5af8aaf95b1be38be6219c1eb84bf4a3e))
* **procedures:** one off-switch per gate, on by default, recorded when used ([c830914](https://github.com/drewdrewthis/claude-plugins/commit/c830914ca485f433e96a98fbdf8aefe59278296a))
* **procedures:** write and validate the record `project:` field end to end ([6810f9b](https://github.com/drewdrewthis/claude-plugins/commit/6810f9ba1f49be0b057c06d095787a70d042705b))


### Bug Fixes

* address CodeRabbit review — vendor marker + POSIX-portable KEYS extraction ([3ed4119](https://github.com/drewdrewthis/claude-plugins/commit/3ed41199bf310eb4265a4e750e1f8429cc8e105c))
* **procedures:** clarify --recurrence-of governs by pattern's earliest ts ([b0a269f](https://github.com/drewdrewthis/claude-plugins/commit/b0a269fbb75ed2765cd9ca3aa67d20f54b8da11f))
* **procedures:** clarify --recurrence-of governs by pattern's earliest ts ([aa74c18](https://github.com/drewdrewthis/claude-plugins/commit/aa74c18e9e83cd73fe3a99d0eaff55f8c6167f40))
* **procedures:** final review polish — pin the shim, correct the comments ([47372f0](https://github.com/drewdrewthis/claude-plugins/commit/47372f07cc99db1d882c69fdbb103783263feb34))
* **procedures:** make --recurrence-of lookup return the pattern's earliest ts ([8b56a1f](https://github.com/drewdrewthis/claude-plugins/commit/8b56a1f33b00d7dc474f2d7038913b0a9d7d054d))
* **procedures:** review — record releases not invocations, correct the docs ([840e799](https://github.com/drewdrewthis/claude-plugins/commit/840e79914946b40bf372fe8eec8d3924b6cc16b4))
* **procedures:** review round 2 — classify releases correctly in both directions ([7501f6c](https://github.com/drewdrewthis/claude-plugins/commit/7501f6c916cff54f33715141f7067ddb341cfc40))
* **procedures:** say WHY how-do-i re-gates each turn in the deny message ([81f6830](https://github.com/drewdrewthis/claude-plugins/commit/81f6830febd2a0cfb2c81123acc7887f0a939030))


### Documentation

* **procedures:** emit the bare earliest ts, not the whole record ([3fd1e3b](https://github.com/drewdrewthis/claude-plugins/commit/3fd1e3ba1b0cd474492550ea93aa309d8539866e))


### Tests

* **procedures:** give the escape-lib mutation sandbox a skills/ dir ([ff3921a](https://github.com/drewdrewthis/claude-plugins/commit/ff3921ac5aa400e746375c5163f157a68fd689aa))
* **procedures:** pin the deny message's reasoning and the per-turn invariant ([28d926e](https://github.com/drewdrewthis/claude-plugins/commit/28d926e41dd7429a1e09c98cbb0f5fa831550865))

## [0.6.0](https://github.com/drewdrewthis/claude-plugins/compare/procedures-v0.5.0...procedures-v0.6.0) (2026-08-18)


### Features

* **recall:** new plugin — /recall over a bundled session index ([#27](https://github.com/drewdrewthis/claude-plugins/issues/27)) ([1f770da](https://github.com/drewdrewthis/claude-plugins/commit/1f770da712b1de86305e57c0da6f73039fd6bd1b))


### Bug Fixes

* **procedures:** close how-do-i-gate allowlist holes (Agent bypass, chain guard) ([#59](https://github.com/drewdrewthis/claude-plugins/issues/59)) ([827da27](https://github.com/drewdrewthis/claude-plugins/commit/827da270532c5acf5c620e3a653331162cccf07d))
* **procedures:** restrict how-do-i-gate Agent allow to compliance dispatches ([827da27](https://github.com/drewdrewthis/claude-plugins/commit/827da270532c5acf5c620e3a653331162cccf07d))

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
