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
/plugin install recall@drewdrewthis
```

## Plugins

### procedures (0.1.0)

The procedural-knowledge system, gates included (gate hooks vendored from
orchard-codex `develop-sweatshop`):

| piece | what |
|---|---|
| `/how-do-i` | the gateway to everything the codex knows — forks the `procedure-scout` agent, which searches the record stores via `scripts/query-records.sh` and returns the governing procedure, verbatim commands, traps, and a standing label per source. `query-records.sh` is its SOLE retrieval surface (survey with `--keyword`/`--kind`/`--links-to`/`--recall`, batch-read with `--cat`); a record it can reach but not query is reported as a matcher/`keywords` bug rather than worked around |
| `digest-record` (PostToolUse:Skill) | stores the digest each `/how-do-i` fork returns, one file per digest under `$TURN_STATE_DIR/digests`, so the next `/how-do-i` in the session starts warm and can separate "already established" from "newly found". Read-only replay via `scripts/session-digest-read.sh --read`; it changes what the fork STARTS WITH, never whether the gate fires |
| `/update-records` | THE single entry point for every knowledge artifact — there is no separate create command. Script-backed via `scripts/log-record.sh`: mistake / decision / solution / failure-mode. Written by hand from `skills/update-records/templates/`: procedure, evolution, and the four rule shapes — principle, invariant, policy, standard. Written by following the longhand procedures in `skills/update-records/references/`: procedure, reference, skill. Carries the test for choosing among the rule kinds |
| record stores | ten, one per GRC artifact class: `failure-modes` (risk register), `decisions` (governance choices), `solutions` (control patterns), `procedures` (control implementations), `research` (evidence), `plans` (roadmap), `principles` (judgment rules), `invariants` (absolute constraints), `policies` (standing authority), `standards` (control objectives). Defined once in `scripts/lib/stores.sh`; discover at runtime with `query-records.sh --list-stores`, never by enumerating them in prose |
| `/am-i-done` | cold-read review of an am-i-done report (incl. the "Procedures followed" evolution table) by the `work-reviewer` agent before calling work done |
| `/evolve-procedure` | patch an EXISTING procedure from a correction, incident, or friction — deviation, missing step, or stale/broken ref; procedures only, every material patch appends a dated line to that procedure dir's `EVOLUTION.md` |
| `how-do-i-gate` (PreToolUse) | blocks tool calls until `Skill(procedures:how-do-i)` has run this turn; fail-open, blind fail-opens recorded |
| `am-i-done-gate` (Stop) | requires one `Skill(procedures:am-i-done)` review on any turn that called tools; asks at most once |
| `turn-state-reset` (UserPromptSubmit) / `turn-state-record` (PostToolUse:Skill) | the turn-boundary state the gates read (`$TURN_STATE_DIR`, default `/tmp/claude-turn-state`) |
| `enforce-frontmatter` (PostToolUse:Write\|Edit) | every record .md written under a store beneath `$KNOWLEDGE_ROOT` (default `~/.claude`) must carry the six-key frontmatter (id, kind, date, keywords, links, status) — vendored `lint-frontmatter.sh`, exit-2 feedback on violation |
| EVOLUTION.md convention | every procedure dir carries an `EVOLUTION.md` log (`evolution.template.md` in `skills/update-records/templates/`) — one dated line per material change, newest first; `/update-records` explains it |

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
  `LINT_FRONTMATTER_ROOT`, `TURN_STATE_DIR`,
  `KNOWLEDGE_ROOT` for the frontmatter hook).
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
  holds the two declarations in agreement. `recall/skills/recall/SKILL.md` pins
  one for the same reason, with no `agent:` to hold it against. Measured on
  this fork path: an opus-parent session's fork moved to `claude-haiku-4-5`
  when the skill declared `model: haiku`, while the parent's own turns stayed
  on opus — the pin binds the fork without touching the caller. Upstream has no
  equivalent because the gate does not run as a forked skill there.

  **This is documented harness design, not a bug — do not refile it.** The
  Claude Code docs state it outright: the fork-vs-named-subagent table in
  [sub-agents](https://code.claude.com/docs/en/sub-agents) gives a fork's
  model as "same as main session" against a named subagent's "from the
  subagent's `model` field", and the
  [skills](https://code.claude.com/docs/en/skills) frontmatter reference says
  that with `context: fork`, a SKILL's `model:` "sets the forked subagent's
  model instead". The skill-level pin is therefore the only control surface on
  this path, and re-declaring it per fork skill is the intended usage rather
  than a workaround. `hooks/tests/scout-retrieval.bats` sweeps every agent
  declaring `model:` across every plugin and requires the fork skill that
  dispatches it to pin the same tier.

- **No upstream counterpart (query-records is now sourced here):**
  orchard-codex#268 phase 1 removed these scripts from the codex, so this
  plugin is the source of truth for `query-records.sh`. Machinery added since
  — `--recall` over `mistakes.jsonl`, and `--cat` for batch full-record
  retrieval — has nothing upstream to stay byte-close to. Each is marked at
  its point of divergence.

- **Fork-path session state:** `hooks/digest-record.sh` +
  `hooks/lib/session-digest.sh` + `scripts/session-digest-read.sh` carry a
  /how-do-i digest forward within one session, so a repeat invocation starts
  warm instead of re-searching the same ground. Same root cause as the model
  pin — the gate runs as a forked skill here and does not upstream — and the
  same storage discipline as `turn-state.sh`: one file per digest, every write
  a fresh file, no read-modify-write. Digests live one level BELOW
  `$TURN_STATE_DIR` precisely so the per-turn reset cannot reach them; the
  gate still fires every turn regardless of what the fork starts with.
  Tunable with `SESSION_DIGEST_DIR` (default `$TURN_STATE_DIR/digests`),
  `SESSION_DIGEST_KEEP` (prior digests replayed per warm start, default 3, `0`
  = uncapped) and `SESSION_DIGEST_TTL_DAYS` (default 2, the only thing that
  ever removes a digest). A non-numeric value on either count falls back to its
  default rather than erroring. A blind failure to store a digest is recorded
  to `GATE_FAILOPEN_LOG` under gate `digest-record` — group by gate before
  computing any fail-open rate, since this one is a writer, not a gate.

- **Fork-path agent prompt:** a `context: fork` skill takes its `agent:` as
  identity only — the agent file's prompt body and its `tools:` allowlist are
  NOT loaded into the fork. The
  [skills](https://code.claude.com/docs/en/skills) fork table gives a forked
  skill's Task as "SKILL.md content" against a system prompt "from agent type",
  and measurement agrees: a distinctive first-action marker injected into
  `agents/procedure-scout.md` ran **zero** times in a live fork, which then used
  the Read tool that `tools: Bash` does not grant. So the retrieval contract —
  the survey → `--cat` batch-read loop, the `UNREACHABLE` bug report, the output
  shape, and the sole-retrieval-surface Boundaries — lives in
  `skills/how-do-i/SKILL.md`, the file that actually binds.
  `agents/procedure-scout.md` keeps the same contract because it still governs a
  direct `Agent(subagent_type:)` spawn, and `hooks/tests/scout-retrieval.bats`
  pins the load-bearing clauses in each file independently so the two cannot
  silently split. Same class as the model pin above: the fork path reads the
  SKILL, never the agent. There is no confirmed skill-level tool restriction for
  forks — `disallowed-tools` is declared on the skill as a best-effort second
  layer, but the docs do not say it reaches a fork, so the prose prohibition is
  the control.

- **Plugin-scoped skill names in gate messages:** the gates' deny/block text
  names `Skill(procedures:how-do-i)` / `Skill(procedures:am-i-done)`, the forms
  that resolve when shipped in a plugin. `hooks/turn-state-record.sh` accepts
  the bare and the scoped form alike, so either satisfies a gate. When the named
  skill file is not readable beside the hooks (`../skills/<name>/SKILL.md`) the
  gate releases instead of denying, recorded as `why:"skill-unresolvable"`.

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

### recall (0.1.0)

`/recall <topic>` — searches what **you and Claude** said in past Claude Code
sessions and synthesizes it into the current one (what it is, what was decided,
where it stands, what's open). Runs in a fork, so reading transcripts never
lands in the main context. Ships the indexer it depends on: `scripts/session-index.py` (an
incremental SQLite FTS5 index over the session transcripts) plus a `SessionEnd`
hook that keeps it warm — the skill also rebuilds on invocation, so the hook is
a latency optimisation, not a correctness requirement.

Scope worth knowing before installing:

- It indexes the **prose of both sides** — your prompts and Claude's replies —
  but not tool calls or their output, so anything Claude only ever wrote into a
  file or a command is not searchable.
- It indexes **every project on the machine** into one store, so `/recall` can
  surface content from unrelated repos or clients. There is no scoping flag.
- Top-level sessions only; subagent transcripts are excluded.

Requires `python3` and a `sqlite3` built with the **FTS5** extension (the default
on most platforms; Alpine's stock sqlite and some conda builds lack it — recall
reports this rather than failing obscurely).

Config: `CLAUDE_CONFIG_DIR` (default `~/.claude`), or `SESSION_INDEX_DB` /
`SESSION_INDEX_PROJECTS` to override either path directly. The index lives at
`~/.claude/sessions.db`; to remove it, `rm ~/.claude/sessions.db*`.

Started from the codex's `scripts/session-index.py` + `hooks/index-sessions.sh`,
but unlike the other plugins this is **a fork, not a vendoring** — the data-root
adaptation is marked `PLUGIN ADAPTATION` as elsewhere, and beyond that the
indexer was substantially rewritten (schema versioning, incremental durability,
provenance from the recorded `cwd`, concurrency-safe open). Do not treat it as
tracking upstream.

`scripts/fts5_query.py` is a separate unit with its own table-driven tests: the
translation of a human's words into an FTS5 MATCH expression has repeatedly
shipped same-class defects, each a *valid* expression that matched the wrong
documents. It has a pure `str -> str` contract; it opens a private in-memory
SQLite connection to ask the tokenizer whether a token indexes to anything, but
touches no on-disk database, filesystem, or environment. Do not reimplement it
in the indexer.

Tests:

```
cd plugins/recall && bats scripts/tests hooks/tests
```

## docs/

`docs/adrs/001-procedural-knowledge-system.md` — the design rationale behind
the procedures plugin, consolidated into one record: the
procedure/skill/hook taxonomy, the per-turn invariant gates, records and
discovery, and the evolution loop.

`docs/principles/` — the binding coding/delegation/docs/clean-up standards,
vendored from the codex. `.claude/agents/` carries the codex reviewer agents
(principles, hygiene, security, test) for working in this repo. See
[CONTRIBUTING.md](CONTRIBUTING.md).
