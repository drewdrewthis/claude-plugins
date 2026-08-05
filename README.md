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

The machinery is vendored from orchard-codex `develop-sweatshop` (skills,
procedure-scout/work-reviewer agents, gate hooks + lib, `query-records.sh` +
`log-record.sh` + `gen-*` view generators + shared awk matcher, linter,
templates) with exactly two classes of deliberate adaptation, each marked
`PLUGIN ADAPTATION` in the source:

- **Data-root defaults:** every script's record-store root defaults to
  `~/.claude` (the host codex) instead of the script's own parent dir —
  upstream the scripts live inside the codex repo; installed as a plugin
  they must not write records into the plugin dir. Override with
  `CODEX_ROOT` (or the per-script vars: `QUERY_RECORDS_ROOT`,
  `MISTAKES_JSONL`, `DECISIONS_DIR`, `SOLUTIONS_DIR`, `FAILURE_MODES_DIR`,
  `LINT_FRONTMATTER_ROOT`, `TURN_STATE_DIR`, `KNOWLEDGE_ROOT` for the
  frontmatter hook).
- **Script paths in skill bodies:** `/log` and the `/how-do-i` fork prompt
  reference the plugin-shipped scripts via `${CLAUDE_SKILL_DIR}` (substituted
  by Claude Code in skill markdown) instead of upstream's repo-relative
  paths.

Verified end-to-end with `claude --plugin-dir`: the gate cycle works as
shipped — `tool_input.skill` arrives as the bare skill name, the reset hook
stamps the turn, the record hook marks `how_do_i`, and the fork dispatches
the plugin's own `procedure-scout`.

**`respond-gate.sh` ships but is NOT wired** in `hooks/hooks.json`: it denies
tool calls until a `/respond` skill has run, and this plugin does not ship a
`/respond` skill — wiring it would brick any consumer without one. Hosts
that have their own `/respond` wire it via their user/project settings.

### Tests

The upstream bats suites for everything shipped here (gates + libs +
fail-open, linter, `query-records.sh` + ranking, index generators) are
vendored under `plugins/procedures/{hooks,scripts}/tests/`. Run:

```
cd plugins/procedures && bats hooks/tests scripts/tests
```

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

`docs/adrs/001-procedural-knowledge-system.md` — the design rationale behind
the procedures plugin, consolidated into one record: the
procedure/skill/hook taxonomy, the per-turn invariant gates, records and
generated views, and the evolution loop.
