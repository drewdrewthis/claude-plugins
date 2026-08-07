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
/plugin install delegation@drewdrewthis
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
| `/log` | durable records: mistake / decision / solution / failure-mode via `scripts/log-record.sh`; `skills/log/templates/` additionally carries the procedure, principle, and evolution shapes, written by hand |
| `/am-i-done` | cold-read review of an am-i-done report (incl. the "Procedures followed" evolution table) by the `work-reviewer` agent before calling work done |
| `/create-new` | create a new procedure/reference/skill for uncovered work — wraps the codex-meta create procedures; draft-then-promote |
| `/evolve-procedure` | patch an EXISTING procedure from a correction, incident, or friction — deviation, missing step, or stale/broken ref; procedures only, every material patch appends a dated line to that procedure dir's `EVOLUTION.md` |
| `how-do-i-gate` (PreToolUse) | blocks tool calls until `Skill(how-do-i)` has run this turn; fail-open, blind fail-opens recorded |
| `am-i-done-gate` (Stop) | requires one `Skill(am-i-done)` review on any turn that called tools; asks at most once |
| `turn-state-reset` (UserPromptSubmit) / `turn-state-record` (PostToolUse:Skill) | the turn-boundary state the gates read (`$TURN_STATE_DIR`, default `/tmp/claude-turn-state`) |
| `enforce-frontmatter` (PostToolUse:Write\|Edit) | every record .md written under a store beneath `$KNOWLEDGE_ROOT` (default `~/.claude`) must carry the six-key frontmatter (id, kind, date, keywords, links, status) — vendored `lint-frontmatter.sh`, exit-2 feedback on violation |
| EVOLUTION.md convention | every procedure dir carries an `EVOLUTION.md` log (`evolution.template.md` in `skills/log/templates/`) — one dated line per material change, newest first; `/log` explains it |

The machinery is vendored from orchard-codex `develop-sweatshop` (skills,
procedure-scout/work-reviewer agents, gate hooks + lib, `query-records.sh` +
`log-record.sh` + shared awk matcher, linter, templates) with deliberate adaptation, marked
`PLUGIN ADAPTATION` in the source where it touches code:

- **Data-root defaults:** every script's record-store root defaults to
  `~/.claude` (the host codex) instead of the script's own parent dir —
  upstream the scripts live inside the codex repo; installed as a plugin
  they must not write records into the plugin dir. Override with
  `CODEX_ROOT` (or the per-script vars: `QUERY_RECORDS_ROOT`,
  `MISTAKES_JSONL`, `DECISIONS_DIR`, `SOLUTIONS_DIR`, `FAILURE_MODES_DIR`,
  `LINT_FRONTMATTER_ROOT`, `TURN_STATE_DIR`, `KNOWLEDGE_ROOT` for the
  frontmatter hook).
- **Script paths in skill/agent bodies:** the skills and agents reference the
  plugin-shipped scripts via `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_SKILL_DIR}`
  (substituted by Claude Code in skill and agent markdown) instead of
  upstream's repo-relative paths, which would resolve against the caller's
  cwd.
- **Fork-skill model pin:** a `context: fork` skill inherits the PARENT
  SESSION's model, not the `model:` its `agent:` declares — the agent-side
  value is only honoured on the `Agent(subagent_type:)` path. So
  `skills/how-do-i/SKILL.md` and `skills/am-i-done/SKILL.md` each re-declare
  `model:` in their own frontmatter, and `hooks/tests/gate-skill-model.bats`
  holds the two declarations in agreement. Measured on this fork path: an
  opus-parent session's fork moved to `claude-haiku-4-5` when the skill
  declared `model: haiku`, while the parent's own turns stayed on opus —
  the pin binds the fork without touching the caller. Upstream has no
  equivalent because the gate does not run as a forked skill there.

Host-neutral wording in place of codex-internal file/hook references is a
further, prose-only adaptation class and is not individually marked.

Verified end-to-end with `claude --plugin-dir`: the gate cycle works as
shipped — `tool_input.skill` arrives as the bare skill name, the reset hook
stamps the turn, the record hook marks `how_do_i`, and the fork dispatches
the plugin's own `procedure-scout`.

### Tests

The upstream bats suites for everything shipped here (gates + libs +
fail-open, linter, `query-records.sh` + ranking) are
vendored under `plugins/procedures/{hooks,scripts}/tests/`. Run:

```
cd plugins/procedures && bats hooks/tests
```

### delegation (0.1.0)

Pick the right specialist, brief it properly, and mint a new one when none
fits. **The machinery ships; the roster is the host's** — this plugin carries
the ROUTER and the RULE FOR MAKING agents, never agent files themselves, so
one plugin serves a fleet whose rosters differ.

| piece | what |
|---|---|
| `/delegate` | classify the task shape (kind / difficulty / focus), run `scripts/route-delegation.sh` for the agent + model + why, then build the briefing — self-contained, result-demanding, coding/docs standards woven in — and verify what comes back |
| `/create-new-sub-agent` | mint the specialist the router had no row for: `templates/agent.template.md` (single mandate, right-sized tier, tools allowlist, tripwires) + `references/write-agent-doc.procedure.md`, written into the host roster |
| `scripts/route-delegation.sh` | the routing table AS A SCRIPT — one row per task shape, each agent's model read LIVE from the roster's `model:` frontmatter, so retuning the roster propagates without editing prose. `--list` dumps every route |
| `scripts/lint-agent-files.sh` | structural lint for agent files: frontmatter + `Role` + `Boundaries`, no dates, no issue refs (hard); size budget and missing `model:` (warn) |

Config: `CLAUDE_AGENTS_DIR` for the roster, else `$CODEX_ROOT/agents`, else
`~/.claude/agents`; `LINT_AGENT_FILES_ROOT` (else `$CODEX_ROOT`, else
`~/.claude`) for the linter — the same data-root chaining as `procedures`.

Router exit codes: `0` matched, `1` usage error, `2` no specialist fits **or
this host has no roster at all**, `3` roster drift. That second exit-2 case is
the deliberate **agent-less degradation**: a fresh tenant that has minted no
agents gets the self-extension rule ("mint one via `/create-new-sub-agent`"),
not a drift error about a corruption that does not exist. A matched agent
missing while *other* agents exist is still exit 3 — real drift.

Vendored from the codex with two of the adaptation classes `procedures` uses,
each marked `PLUGIN ADAPTATION`: data-root defaults, and host-neutral wording
in place of codex-internal file/hook references. (No fork-skill model pin here
— this plugin ships no `context: fork` skill.) Tests:

```
cd plugins/delegation && bats scripts/tests
```

### about-my-person (0.1.0)

`/about-my-person` — maintains the ONE whole-readable file about who your
person is (Identity / Preferences / Standing context / dated Changelog):
read whole, replace stale facts, never append blind, no secrets ever.
Lives in a directory alongside `EVOLUTION.md` (dated one-line log of
material profile changes, newest first). Config: `ABOUT_MY_PERSON_DIR`
(default `~/.claude/about-my-person`) or `ABOUT_MY_PERSON_FILE` to override
the file path directly.

### take-note (0.1.0)

Daily working notes: `/take-note` scratchpad (one file per day, rollover with
carry-over) + a SessionStart hook loading today's (or yesterday's) note and
`ABOUT_MY_PERSON.md` when present. Config: `KNOWLEDGE_WS` (default
`~/workspace`) or `NOTES_DIR` directly.

## docs/

`docs/adrs/001-procedural-knowledge-system.md` — the design rationale behind
the procedures plugin, consolidated into one record: the
procedure/skill/hook taxonomy, the per-turn invariant gates, records and
discovery, and the evolution loop.

`docs/principles/` — the binding coding/delegation/docs/clean-up standards,
vendored from the codex. `.claude/agents/` carries the codex reviewer agents
(principles, hygiene, security, test) for working in this repo. See
[CONTRIBUTING.md](CONTRIBUTING.md).
