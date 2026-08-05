# claude-plugins

Drü's Claude Code plugin marketplace. Versioned home for the machinery shared
across the personal fleet AND the AppleTree tenant base — one source, two
consumers, no copy drift. **Machinery only:** the knowledge files the agent
generates live outside the plugins, under `~/.claude/references/**` per the
design record.

## Install

```
/plugin marketplace add drewdrewthis/claude-plugins
/plugin install procedures@drewdrewthis
/plugin install about-my-person@drewdrewthis
/plugin install take-note@drewdrewthis
```

## Plugins

### procedures (0.1.0)

The procedural-knowledge system, gates included (gate hooks vendored from
orchard-codex `develop-sweatshop`):

| piece | what |
|---|---|
| `/how-do-i` | the gateway to everything the codex knows — forks the `procedure-scout` agent, which searches the record stores via `scripts/query-records.sh` and returns the governing procedure, verbatim commands, traps, and a standing label per source |
| `/log` | durable records: procedure / decision / solution / principle / failure-mode — `*_TEMPLATE.md` files in `skills/log/templates/` (PROCEDURE, DECISION, SOLUTION, PRINCIPLE, FAILURE_MODE, EVOLUTION) |
| `/am-i-done` | cold-read review of a handoff report (incl. the "Procedures followed" evolution table) by the `work-reviewer` agent before calling work done |
| `/evolve` | patch an existing procedure/skill/record from a correction or friction — wraps the codex-meta evolve procedures |
| `/create-new` | create a new procedure/reference/skill for uncovered work — wraps the codex-meta create procedures; draft-then-promote |
| `how-do-i-gate` (PreToolUse) | blocks tool calls until `Skill(how-do-i)` has run this turn; fail-open, blind fail-opens recorded |
| `am-i-done-gate` (Stop) | requires one `Skill(am-i-done)` review on any turn that called tools; asks at most once |
| `turn-state-reset` (UserPromptSubmit) / `turn-state-record` (PostToolUse:Skill) | the turn-boundary state the gates read (`$TURN_STATE_DIR`, default `/tmp/claude-turn-state`) |
| `enforce-frontmatter` (PostToolUse:Write\|Edit) | every record .md written under a store beneath `$KNOWLEDGE_ROOT` (default `~/.claude`) must carry the six-key frontmatter (id, kind, date, keywords, links, status) — vendored `lint-frontmatter.sh`, exit-2 feedback on violation |
| EVOLUTION.md convention | every procedure dir carries an `EVOLUTION.md` log (template in `skills/log/templates/`) — one dated line per material change, newest first; `/log` explains it |

The machinery is copied byte-for-byte from orchard-codex `develop-sweatshop`
(skills, procedure-scout/work-reviewer agents, gate hooks + lib,
`query-records.sh` + `log-record.sh` + `gen-*` view generators + shared awk
matcher, linter, templates). It assumes the codex layout rooted at
`~/.claude` — record stores under `~/.claude/references/**`,
`~/.claude/mistakes.jsonl`, scripts reachable per the SKILL docs. Env
overrides where the upstream scripts define them (`QUERY_RECORDS_ROOT`,
`MISTAKES_JSONL`, `DECISIONS_DIR`, `SOLUTIONS_DIR`, `FAILURE_MODES_DIR`,
`TURN_STATE_DIR`, `LINT_FRONTMATTER_ROOT`, `KNOWLEDGE_ROOT` for the
frontmatter hook).

### about-my-person (0.1.0)

`/about-my-person` — maintains the ONE whole-readable file about who your
person is (Identity / Preferences / Standing context / dated Changelog):
read whole, replace stale facts, never append blind, no secrets ever.
Config: `ABOUT_MY_PERSON_FILE` (default
`~/workspace/references/docs/ABOUT_MY_PERSON.md`).

### take-note (0.1.0)

Daily working notes: `/take-note` scratchpad (one file per day, rollover with
carry-over) + a SessionStart hook loading today's (or yesterday's) note and
`ABOUT_MY_PERSON.md` when present. Config: `KNOWLEDGE_WS` (default
`~/workspace`) or `NOTES_DIR` directly.

## docs/

`docs/adrs/` — the ADRs and decision records behind this system, copied from
orchard-codex (per-turn invariant gates, done-gate design, procedure = prose
script / skill = executor, atomic unit is the document, scenario-driven
evolution, skill-is-a-gateway). `docs/procedure-evolution.md` — the
generative-loop principle EVOLUTION.md logging serves.

Origin: skills extracted 2026-08-05 from `appletree-base`; gates, linter, and
ADRs from `orchard-codex@develop-sweatshop`.
