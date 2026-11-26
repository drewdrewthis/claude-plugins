# Lenses — domain registry for /improve and /delegate

One section per lens. A lens is a domain, the agent that judges it, and the questions it asks.

- **always** — `yes`: /improve runs it on every artifact.
- **triggers** — examples of the domain: words and path globs. Match by meaning, not by string; a passing mention is not a match.
- **agent** — a name in the host roster, or `none`. Missing or `none` → the caller runs the questions through a read-only reviewer.
- **questions** — 3 to 5, each answerable from the artifact plus its context.

Add a lens: copy a section, fill all four fields.

## stress-test
- always: yes
- triggers: any idea, plan, design, PR
- agent: devils-advocate
- questions:
  1. Which assumption, if false, breaks this?
  2. What fails first under real load, bad input or partial failure, and how would anyone notice?
  3. What cheaper or already-existing alternative was skipped?
  4. What is the undo if it is wrong?

## simplicity
- always: yes
- triggers: any idea, plan, design, PR
- agent: principles-reviewer
- questions:
  1. What can be removed with no loss to the goal?
  2. Does each part have one job?
  3. Is anything built that the platform, a library or the codebase already does?
  4. Can the next reader understand it in 30 seconds?

## harness
- always: no
- triggers: hooks, skills, subagents, plugins, settings scopes, permissions, MCP servers, compaction, CLAUDE.md, agent memory; `.claude/**`, `**/CLAUDE.md`, `**/SKILL.md`, `**/hooks/**`, `plugins/**`, `**/settings*.json`
- agent: harness-engineer
- questions:
  1. Which native harness feature already does this (docs link), and what code is left after using it?
  2. Which scope (managed, user, project, local, plugin) does it live in, and when does it take effect?
  3. Does it hold the turn and for how long, does it fail open or closed, and can it loop?
  4. Is meaning judged by a model rather than a regex or keyword list?
  5. How will it be proven to fire in a real session?

## security
- always: no
- triggers: auth, login, sessions, secrets, tokens, API keys, credentials, PII, allowlists, network exposure, logs of user data; `**/.env*`, `**/auth/**`, `**/*secret*`
- agent: security-reviewer
- questions:
  1. Where can a secret or PII end up (logs, transcripts, URLs, commits, other agents)?
  2. Who can trigger this, and can untrusted input (a channel message, a web page) steer it?
  3. What is the least privilege it needs, and what does it get?
  4. What happens to credentials when it fails or is undone?

## ux
- always: no
- triggers: screens, pages, flows, navigation, information architecture, onboarding, sharing and permission UI, forms, dashboards; `**/*.tsx`, `**/pages/**`, `**/components/**`
- agent: ux-designer
- questions:
  1. Who is the user, and what are they trying to finish here?
  2. What do they see on first use, on an empty state, and on an error?
  3. How does a proven product model the same job?
  4. What can leave the screen without losing the decision it supports?

## infra-ops
- always: no
- triggers: systemd units and timers, cron, boxes and VMs, docker, tmux sessions, agent fleet runtime, memory, OOM, swap, disk, egress, deploys, backups
- agent: none
- questions:
  1. What does it cost in RAM, CPU and disk on a shared box, and what happens at the limit?
  2. How does it restart, and can a restart orphan or duplicate a process?
  3. How is failure detected, and who is told?
  4. Is the change in config-as-code, or will the next rebuild drop it?
  5. What is the rollback, and does it need downtime?

## tests
- always: no
- triggers: tests, specs, fixtures, test doubles, CI test jobs, coverage; `**/tests/**`, `**/*.test.*`, `**/*.spec.*`, `**/*.bats`, `**/*.feature`
- agent: test-reviewer
- questions:
  1. Does each behavior have a test at the right pyramid level?
  2. Does each test fail when the behavior breaks, not only when the code changes?
  3. Are doubles fakes at real boundaries, not mocks of owned code?
  4. Which edge or failure case has no test?

## langwatch
- always: no
- triggers: LangWatch, traces, spans, evaluations, scenarios, agent simulations, prompt management, OTEL export to LangWatch; `**/langwatch/**`, `**/scenarios/**`
- agent: langwatch-expert
- questions:
  1. Does it use the LangWatch SDK or API the documented way for the version in use?
  2. Do traces and evaluations carry what the UI needs (names, metadata, thread ids)?
  3. Does each scenario exercise the agent end to end, with a clear success judge?
  4. Does any user content leave in telemetry that should not?
