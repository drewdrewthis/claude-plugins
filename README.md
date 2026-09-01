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
/plugin install worklog@drewdrewthis
/plugin install delegation@drewdrewthis
/plugin install about-my-person@drewdrewthis
/plugin install take-note@drewdrewthis
/plugin install recall@drewdrewthis
/plugin install heartbeats@drewdrewthis
```

## Plugins

### procedures (0.3.0)

The procedural-knowledge system, gates included (gate hooks vendored from
orchard-codex `develop-sweatshop`):

| piece | what |
|---|---|
| `/what-do-i-know` | the gateway to everything the codex knows — procedures, decisions, solutions, references, principles, research, not procedures alone — runs the two-stage retrieval pipeline (`scripts/how-do-i.sh`): stage 1 (fast model, prompt inlined in the script) picks relevant records from a numbered index built by `build-record-index.sh` over every store, `compile-records.sh` assembles their full text, stage 2 (strong model, prompt inlined in the script) writes the answer — governing record, verbatim commands, traps, cited to source paths. One pipeline run per invocation; a record it should have surfaced is reported as a selection gap rather than worked around |
| `/how-do-i` | deprecated alias for `/what-do-i-know` — same script, same contract; kept functional so a session naming `Skill(procedures:how-do-i)` (old habit, or a re-armed `enable_how_do_i_gate`) still gets a correct answer |
| `/update-records` | THE single entry point for every knowledge artifact — there is no separate create command. Script-backed via `scripts/log-record.sh`: mistake / decision / solution / failure-mode. Written by hand from `skills/update-records/templates/`: procedure, evolution, and the four rule shapes — principle, invariant, policy, standard. Written by following the longhand procedures in `skills/update-records/references/`: procedure, reference, skill. Carries the test for choosing among the rule kinds |
| record stores | ten, one per GRC artifact class: `failure-modes` (risk register), `decisions` (governance choices), `solutions` (control patterns), `procedures` (control implementations), `research` (evidence), `plans` (roadmap), `principles` (judgment rules), `invariants` (absolute constraints), `policies` (standing authority), `standards` (control objectives). Defined once in `scripts/lib/stores.sh`; `build-record-index.sh` discovers them at runtime, never by enumerating them in prose |
| `/adherence-check` | cold-read review of an adherence-check report by the `work-reviewer` agent — self-invoked whenever you want a second, skeptical pass before calling work done; not a gate obligation. Findings only; record evolution is the evolve-sweep hook's job, not the review's |
| `/am-i-done` | deprecated alias for `/adherence-check` — same fork, same contract; kept functional so a session naming `Skill(procedures:am-i-done)` (old habit, or a re-armed `enable_am_i_done_gate`) still gets a correct review |
| `/evolve-procedure` | patch an EXISTING procedure from a correction, incident, or friction — deviation, missing step, or stale/broken ref; procedures only, every material patch appends a dated line to that procedure dir's `EVOLUTION.md` |
| `how-do-i-gate` (PreToolUse) | OFF by default (`enable_how_do_i_gate`) — `nudge` (below) reminds instead. Armed, it blocks tool calls until `Skill(procedures:how-do-i)` has run this turn; fail-open, blind fail-opens recorded |
| `am-i-done-gate` (Stop) | OFF by default (`enable_am_i_done_gate`) — `nudge` (below) reminds instead. Armed, it requires one `Skill(procedures:am-i-done)` review on any turn that called tools; asks at most once |
| `nudge` (UserPromptSubmit) | ON by default (`enable_nudge`) — one reminder line per turn that `/what-do-i-know` and `/adherence-check` exist; main-session turns only, silent for subagents; suppressing it is still recorded like any other switch flip |
| `worklog-record` (Stop, `worklog` plugin) | appends one JSONL line per turn telling the turn's story — what was asked, what came of it, what went wrong: the mechanical half (`session`, `ask_uuid`, `end_uuid`) read from the transcript, and three judged arrays `requests[]`, `outcomes[]`, `mistakes[]` from a cheap model. Every entry is `{text, quote, uuid}` (`mistakes` carries `uuids[]`, needing the offense AND the correction): `text` is the model's summary, capped at 100 characters; `quote` is the evidence it rests on, capped at 120, stored as a run SLICED OUT of the cited candidate's body — located by the model's string, never copied from it. The model may only COPY uuids from a candidate list, and an entry whose quote does not appear in the body of the line it cites is DROPPED WHOLE, never stored quote-less. The caps are a readability bound, not a measured one. Never blocks and never emits a `decision`; runs detached so it cannot serialize a finishing worker. One row per turn, keyed on `ask_uuid`, because `am-i-done-gate` blocking the first Stop and releasing the next makes two Stop fires per turn the normal path. Both fires DETACH, so they overlap: the second starts while the first is still inside its judgment call and has written nothing. A store scan alone would therefore miss and duplicate, so the turn is claimed atomically with `mkdir` before the model call (`WORKLOG_CLAIM_TTL_SECS`, default settle + model timeout + 60s, after which a marker left by a killed fire is stealable — so a crash costs at most that turn's row, never a permanent hole). Store `WORKLOG_JSONL` (default `$HOME/.claude/worklog/<project-slug>.jsonl` — deliberately NOT under `~/.claude/projects/`, which other tools glob for session files); `WORKLOG_SETTLE_SECS` (default 3, the transcript tail lags Stop), `WORKLOG_WINDOW` (candidate records offered to the model, default 60), `WORKLOG_MODEL` (default `claude-haiku-4-5-20251001`), `WORKLOG_MODEL_TIMEOUT` (default 120s), `WORKLOG_DEDUP_SCAN` (rows scanned for the dedup key, default 500), `WORKLOG_CLAIM_TTL_SECS` (above), `WORKLOG_SYNC=1` (run inline instead of detached, for tests — note it also hides the concurrency the claim exists for, so it is not the shape to test ordering in), `WORKLOG_DISABLE` (any non-empty value = off; also the child's re-entrancy guard). A non-numeric value on any count falls back to its default rather than erroring. `WORKLOG_WINDOW`, `WORKLOG_MODEL_TIMEOUT`, `WORKLOG_DEDUP_SCAN` and `WORKLOG_CLAIM_TTL_SECS` also reject `0` — for `WORKLOG_DEDUP_SCAN` that is a correctness boundary, because `tail -n 0` succeeds silently and a zero scan would switch the one-row-per-turn dedup off, and for `WORKLOG_CLAIM_TTL_SECS` because a zero TTL makes every claim instantly stealable, which is the race with an extra step. `WORKLOG_SETTLE_SECS` accepts `0` deliberately, so tests can skip the settle wait |
| `evolve-sweep` (Stop, async) | after each tool-using turn, one cheap-model triage over the final assistant message decides whether the turn looks evolvable; when it does, wakes the session once (`asyncRewake`) to dispatch `procedure-evolver`, which reviews the full turn transcript and updates records itself. Detector only — never writes a record, never stages a file; silent-degrades on triage failure (no failopen spam); no `stop_hook_active` guard so gate-blocked turns are still swept; off-switch `enable_evolve_sweep` |
| `turn-state-reset` (UserPromptSubmit) / `turn-state-record` (PostToolUse:Skill) | the turn-boundary state the gates read (`$TURN_STATE_DIR`, default `/tmp/claude-turn-state`) |
| `enforce-frontmatter` (PostToolUse:Write\|Edit) | every record .md written under a store beneath `$KNOWLEDGE_ROOT` (default `~/.claude`) must carry the six-key frontmatter (id, kind, date, keywords, links, status) — vendored `lint-frontmatter.sh`, exit-2 feedback on violation; off-switch `enable_frontmatter_check` |
| EVOLUTION.md convention | every procedure dir carries an `EVOLUTION.md` log (`evolution.template.md` in `skills/update-records/templates/`) — one dated line per material change, newest first; `/update-records` explains it |

The machinery is vendored from orchard-codex `develop-sweatshop` (skills,
the `work-reviewer` agent, gate hooks + lib, the two-stage
retrieval pipeline — `how-do-i.sh`, `build-record-index.sh`,
`compile-records.sh` — plus `log-record.sh`, linter, templates) with deliberate
adaptation, marked `PLUGIN ADAPTATION` in the source where it touches code:

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
  `skills/am-i-done/SKILL.md` re-declares `model:` in its own frontmatter, and
  `hooks/tests/gate-skill-model.bats` holds it in agreement with the agent it
  forks. `recall/skills/recall/SKILL.md` pins one for the same reason, with no
  `agent:` to hold it against. Measured on
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
  than a workaround. `hooks/tests/gate-skill-model.bats` sweeps every agent
  declaring `model:` across every plugin and requires the fork skill that
  dispatches it to pin the same tier.

- **No upstream counterpart (the retrieval pipeline is sourced here):**
  orchard-codex#268 removed its query machinery from the codex, and this
  plugin's own `query-records.sh` matcher was dropped in favour of the
  two-stage index pipeline (`how-do-i.sh`, both stages' prompts inlined in
  the script rather than dispatched as agents — see its own header — plus
  `build-record-index.sh` and `compile-records.sh`) — all plugin-local,
  nothing upstream to stay byte-close to.

- **No upstream counterpart (post-turn evolution detector):** `hooks/evolve-sweep.sh`
  and its `enable_evolve_sweep` switch are new machinery, not vendored — a port of
  the Hermes post-turn background-review pattern (detect evolvable material each
  turn, wake once, let the dispatched agent write). The hook is a DETECTOR: it
  never writes a record and never stages a file; judgment and every write belong
  to `agents/procedure-evolver.md`, which it reaches by waking the session.
  Its silent-degrade posture (token/curl/parse failures exit 0 with no record)
  is a deliberate third release class documented in `docs/adrs/001`. Tunable:
  `EVOLVE_SWEEP_MODEL` (default `claude-haiku-4-5`). Requires
  `$HOME/.claude/.credentials.json` (claudeAiOauth token) — tokenless installs
  degrade to inert on every turn.

- **Owner-directed behavioral divergence (issue #130):** evolution dispatch was
  removed from `skills/am-i-done/SKILL.md` and `agents/work-reviewer.md` — both
  otherwise byte-close vendored files — and `query-shape-guard.sh` now denies
  Agent for BOTH forks. Dated markers at each removal site are load-bearing:
  without them a `develop-sweatshop` re-sync resurrects a dispatch contract the
  guard denies.

- **Turn worklog:** the `worklog` plugin's `hooks/worklog-record.sh` records one line per turn (shape
  and tunables in the table above) so a later pass can see what happened
  without trawling raw transcripts. "One line per turn" is enforced against
  CONCURRENT writers, not merely repeated ones: `am-i-done-gate` blocking the
  first Stop and releasing the next makes two fires per turn normal, both
  detach, and the second reaches the store while the first is still inside a
  judgment call that has appended nothing. So a `mkdir`-atomic claim keyed on
  `ask_uuid` decides which fire owns the turn before either pays for a model
  call, and the store scan stays as the durable record behind it. Three further
  constraints are not preferences. A `quote` is never stored as the model typed
  it: the model's string only LOCATES the body of the candidate line it cites,
  and the matching run is then sliced out of that body and stored — in the
  whitespace-collapsed form the slicer already gave the bodies. An entry whose
  quote locates nothing is DROPPED WHOLE rather than stored quote-less, because
  a claim wearing the shape of evidence is worse than no claim; and the quote is
  matched against the body of the line the entry POINTS AT, not against the
  candidate blob, so a real sentence attributed to the wrong line fails too.
  Every other pointer in the row is likewise the transcript's own text rather
  than the model's retyping of it. It
  never writes `$HOME/.claude/mistakes.jsonl`: rows there are promoted into
  `references/failure-modes/` and thence into the `@`-imported
  `common-mistakes.md`, where one bad row becomes a fleet-wide rule, so
  `mistakes` here is deliberately inert — an entry or none, no severity, no
  category, no failure-mode name, each of those being a corpus-relative
  judgment this hook has no standing to make. And the worklog does not live
  beside the
  session transcript: `~/.claude/projects/` is globbed for `*.jsonl` by
  consumers that treat what they find as session data, so a file rewritten
  every turn in that directory is swept into corpus and, where a consumer
  takes the newest match, mistaken for the transcript itself.
  Dependencies are `jq` and `python3` (the per-entry slice and the mtime read
  need the interpreter; a missing `jq` is itself a recorded fail-open). The
  judgment call is time-boxed by whichever of `timeout`, `gtimeout`, or `perl`
  is present — so a stock macOS with no GNU coreutils still bounds it via
  `perl` rather than, as an earlier cut did, dropping the whole call under a
  missing `timeout`; if none of the three exists the call runs uncapped and
  logs a `no-timeout` note rather than silently skipping.

- **Fork-path agent prompt:** a `context: fork` skill takes its `agent:` as
  identity only — the agent file's prompt body and its `tools:` allowlist are
  NOT loaded into the fork. The
  [skills](https://code.claude.com/docs/en/skills) fork table gives a forked
  skill's Task as "SKILL.md content" against a system prompt "from agent
  type". So `am-i-done`'s review
  contract — what to read, the verdict shape, the sole-review-surface
  Boundaries — lives in `skills/am-i-done/SKILL.md`, the file that actually
  binds; `agents/work-reviewer.md` governs only a direct
  `Agent(subagent_type:)` spawn. Same class as the model pin above: the fork
  path reads the SKILL, never the agent. There is no confirmed skill-level tool
  restriction for forks — `disallowed-tools` is declared on the skill as a
  best-effort second layer, but the docs do not say it reaches a fork, so the
  prose prohibition is the control.

- **Plugin-scoped skill names in gate messages:** the gates' deny/block text
  names `Skill(procedures:how-do-i)` / `Skill(procedures:am-i-done)`, the forms
  that resolve when shipped in a plugin. `hooks/turn-state-record.sh` accepts
  the bare and the scoped form alike, so either satisfies a gate. When the named
  skill file is not readable beside the hooks (`../skills/<name>/SKILL.md`) the
  gate releases instead of denying, recorded as `why:"skill-unresolvable"`.

- **Configuration surface:** `hooks/lib/gate-escape.sh` and the `userConfig`
  block in `.claude-plugin/plugin.json` have no upstream counterpart. In a
  checkout you change a gate's behavior by editing it; installed as a plugin
  you cannot, and the only alternative is uninstalling the whole plugin. Six
  booleans, read by their own hook alone, each recorded to `gate-escape.jsonl`
  on any explicit flip away from its default:

  - **Default OFF** (soft — `nudge` reminds instead of enforcing):
    `enable_how_do_i_gate`, `enable_am_i_done_gate`, `enable_query_shape_guard`.
    Explicitly setting one `true` arms it, recorded as `armed_by`.
  - **Default ON:** `enable_frontmatter_check`, `enable_evolve_sweep`,
    `enable_nudge`. Explicitly setting one `false` releases it, recorded as
    `released_by`.

  Both directions share one `ge_enabled` function and one log; only the
  per-key default differs, so a hook's own `ge_enabled "$KEY"` call site never
  changes when a key's default polarity does.

  Two channels, and **only one of them is trusted**. The userConfig option
  (`CLAUDE_PLUGIN_OPTION_ENABLE_*`) resolves from user/managed settings only
  from Claude Code v2.1.207, so a cloned repo's `.claude/settings.json` cannot
  set it — a floor nothing here enforces, so an older CLI loses even that. The
  plain `PROCEDURES_ENABLE_*` var is **untrusted ambient config**: a project's
  own settings `env` block reaches hook subprocesses on every version, as do
  `.envrc`, a Makefile, or a wrapper launcher. It exists because a userConfig
  option has no per-invocation override, not because it is safe. If you need
  the anti-clone property, set the option and do not rely on the env var.

Host-neutral wording in place of codex-internal file/hook references is a
further, prose-only adaptation class and is not individually marked.

To verify a checkout end-to-end, arm the gates (`enable_how_do_i_gate` /
`enable_am_i_done_gate`, off by default) and run the cycle under
`claude --plugin-dir`: `tool_input.skill` must arrive as the bare skill name,
the reset hook stamp the turn, the record hook mark `how_do_i` / `am_i_done`,
and the `am-i-done` fork dispatch the plugin's own `work-reviewer`.

### Tests

The bats suites for everything shipped here (gates + libs + fail-open,
linter, the retrieval pipeline) live under `plugins/procedures/hooks/tests/`.
Run:

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

### heartbeats (0.1.0)

`/heartbeats` — the crontab as generated output. One markdown unit file per
recurring job (`name`, `cron`, `command`, `log`, `enabled`, plus a required
`suspension_reason` + `restore_condition` when disabled); the script renders
them into a single marker-delimited block and can `render`, `diff`,
`drift-check`, or `install` it.

Guarantees:

- **Only the managed block is ever rewritten.** Lines outside the markers come
  back byte for byte, CR bytes and all — absent a concurrent writer, since cron
  exposes no lock and read-modify-write over a crontab is inherently racy. The
  one normalisation is that a crontab whose last line lacks a newline gets one
  on the next install that actually writes. Note that some cron builds
  (Debian-family) prepend their own generated preamble to `crontab -l` output;
  those lines are outside the managed block, so they are faithfully written
  back and can accumulate across installs through no fault of this tool.
- **No auto-install.** `install` without `--approve` is a dry run that exits 2
  having written nothing. It renders the block and diffs it against the live
  managed region — that much it has to do to show you anything — and stops
  there: the spliced crontab body is not computed until the approval gate has
  been passed, so there is no dry-run path that builds one.
- **It fails closed, loudly.** One unreadable unit renders nothing rather than
  a partial block; a crontab with unpaired or duplicated markers is an error on
  every operation rather than a "no block yet"; a `crontab -l` that fails for
  any reason other than "no crontab for this user" is an error rather than an
  empty crontab. Each of those defaults would end with a crontab containing the
  managed block and nothing else.
- **Suspended jobs stay visible**, rendered as a commented line carrying the
  reason and the restore condition, rather than vanishing from the file.

Requires `python3` (stdlib only). Config: `HEARTBEATS_UNITS_DIR`, else
`CODEX_ROOT` (default `~/.claude`) giving `<root>/heartbeats/units`.
`HEARTBEATS_CRONTAB_FILE` substitutes a plain file for the real crontab and
exists so the tests never touch one.

Tests:

```bash
cd plugins/heartbeats && bats scripts/tests
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
