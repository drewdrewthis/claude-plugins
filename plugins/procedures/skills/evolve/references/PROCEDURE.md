---
id: proc.codex-meta.evolve
kind: procedure
date: 2026-06-25
keywords: [evolve, improve, patch, behavior, correction, skill-evolution, codify, learn]
links: []
status: active
---

# /evolve

Dispatches to `steps/evolve-skill.md`, `/log mistake`, the create-skill procedure (`references/procedures/codex-meta/create-skill/PROCEDURE.md`), or direct CLAUDE.md / agent / hook / reference edits. Does NOT edit artifacts directly.

`steps/evolve-skill.md` is the precision routine for SKILL.md patches — open and execute it inline.

**$ARGUMENTS:** non-empty → correction is from there; empty → scan current conversation for the most recent correction/friction/surprise.

## Step 0: Track Progress

Create one task for each phase below via TaskCreate. Chain sequential phases with addBlockedBy. Update to `in_progress` on start, `completed` on finish.

## Phase 1: Frame the Correction

State, in 1–3 sentences:

- **What happened** — the specific behavior that needs to change
- **Why it happened** — the missing knowledge, wrong default, or stale instruction behind it
- **What "fixed" looks like** — the behavior next time

If `$ARGUMENTS` is non-empty, this comes from there. Otherwise, extract it from the most recent corrections in the conversation. If nothing actionable is found, say so and stop — not every conversation produces an evolution.

## Phase 2: Survey Touchpoints

Auto-dispatch mode: survey every relevant surface, decide which ones need to change. Touchpoints in scope:

| Surface | When to patch it |
|---|---|
| **Existing skill** (`~/.claude/skills/<name>/SKILL.md`) | Mistake happened *during* a skill, or a skill should have prescribed the missing step. Read and follow `steps/evolve-skill.md` (sibling step file) for `<name>`. |
| **New skill** (create-skill procedure: `references/procedures/codex-meta/create-skill/PROCEDURE.md`) | A workflow was performed ad-hoc that's worth promoting to a skill (used repeatedly, multi-step, has a clear trigger). |
| **Project CLAUDE.md** | Repo-specific rule (DB conventions, command preferences, test patterns). Edit the "Common Mistake / Correct Behavior" table in the relevant project's CLAUDE.md. |
| **Global CLAUDE.md** (`~/.claude/CLAUDE.md`) | Cross-repo personal rule (identity, standards, autonomy). Edit sparingly — global rules are heavy. |
| **Agent** (`~/.claude/agents/<name>.md`) | Behavior of a specific agent (e.g., `lead`, `coder`, `hygiene-reviewer`) needs adjusting. |
| **Hook** (`~/.claude/hooks/`, `settings.json`) | Automated enforcement needed (a behavior the model keeps forgetting → make the harness enforce it). Use `/update-config` to manage hooks. |
| **Reference** (`~/.claude/references/<topic>.md`) | Reusable recipe, pattern, or knowledge dump that multiple skills/agents should link to. |
| **Procedures** (`references/procedures/<cat>/<name>/PROCEDURE.md` + `EVOLUTION.md`) | If a procedure was followed this session and hit friction/deviation/broken-ref, run `steps/evolve-procedure.md` against it. |
| **Decision-record store** (`~/.claude/references/decisions/`) | Decision record — a non-trivial call made with `/decide` that future sessions should respect (reusable recipes go in `~/.claude/references/solutions/`). Replaced the retired `wisdom/` store 2026-05-31. |
| **Auto-memory** (`memory/`) | User preference, project state, ephemeral context. Use the built-in auto-memory writer, not this skill. |
| **Mistakes log** (`~/.claude/mistakes.jsonl`) | *Always* log via `/log mistake` if a correction occurred — this is the data layer that the `steps/evolve-skill.md` routine and the deep-reflect procedure (`references/procedures/research-think/deep-reflect/PROCEDURE.md`) consume later. |

**A single correction often touches more than one surface.** Example: missing step during the launch procedure (`references/procedures/fleet-session/lifecycle/PROCEDURE.md#launch`) → patch the procedure doc AND log the mistake AND maybe add a row to project CLAUDE.md if it's a recurring class.

Quick grep helps: search `~/.claude/references/` (decisions, solutions, failure-modes) frontmatter `keywords` for 1–3 keywords from the correction to avoid duplicating an existing rule.

## Phase 2.5: Classify → capture scenario (corrective) OR edit directly (factual)

### Step 1 — Classify the change

Ask: **is there an agent behavior to assert, or only a fact to record?**

| Change type | Lane |
|---|---|
| Behavioral / corrective — a mistake, trap, confusion, an uncovered situation | **Scenario-first** (steps below) |
| Pure factual / mechanical — renamed flag, moved path, no behavior to assert | **Direct procedure edit** — skip to Phase 3 |

Doctrine: `references/decisions/2026-06-19-scenario-driven-evolution.md`.

### Step 2 — Capture the scenario (behavioral/corrective lane only)

Capture the situation as a **new scenario** (or a new criterion on an existing baited scenario that already provokes the same trap) in the appropriate set file under `scenario-tests/sets/` (usually `failure-modes.json`). Use the JSON format from those files:

- `situation` / `description` — what the agent was doing when the trap fired
- `_fm` map — failure-mode ids encountered (`fm.<id>`)
- `script_plan` (or `user_opening`) — the baited input that would reproduce the trap
- `criteria` / `judge` — falsifiable assertions on observable evidence (tools block or reply shape)
- `trap` — the failure mode in one line
- `verification: "pending"` — **always pending at capture time**

Mental model: "I came across this scenario, here is what I did, here is what I did wrong while trying to do right." This is the **red test** — it should FAIL or be uncovered today. Do NOT edit any procedure yet; the procedure edit falls out of making the scenario green.

After capturing, note: a separate worktree/branch will optimize the scenario to green; the procedure edit (CREATE or PATCH per `references/principles/procedure-evolution.md`'s draft→active norm) follows from that work, not from this turn.

**Promotion gate for the scenario:** `verification: pending` → live only after a second distinct session confirms it passes on the baited input. When that happens, add a `scenario:` / `criterion:` back-reference to the failure-mode record.

### Step 3 — Rank by recurrence → promote to a failure-mode record

The mistakes log is the data layer; the `references/failure-modes/` records are the registry; `references/common-mistakes.md` is the GENERATED, always-loaded (via `@`-import in CLAUDE.md) distillate built from those records ranked by recurrence. A mistake earns a record by **recurring**, not by being recent. Rank candidates:

```bash
# Patterns by recurrence count — chains pointing at the same earliest ts, plus repeats of a named pattern.
grep -oE '"recurrence_of":"[^"]+"' ~/.claude/mistakes.jsonl | sort | uniq -c | sort -rn | head
grep -oE '"pattern":"[^"]+"' ~/.claude/mistakes.jsonl | sort | uniq -c | sort -rn | head
```

Promotion rule:
- **≥3 occurrences** of one pattern (by `recurrence_of` chain or repeated `pattern` id) AND no matching record → invoke **`/log failure-mode <slug> "<rule sentence>"`** to write the `references/failure-modes/<slug>.md` record (`## Mistake` + `## Correct` sections — a *preemptive redirect*, not a war story) and re-render `common-mistakes.md`. That skill owns the record format and the `gen-common-mistakes.sh` run; do NOT hand-write the record or call the generator from here. The generator ranks by recurrence; there is no manual row placement.
- Keep records SHARP — `common-mistakes.md` loads every session. A pattern that stops recurring after its fix landed is a candidate for *demotion*: set the record's `status: superseded-by:<id>` (or delete it) and regenerate; the mistakes.jsonl history remains as the archive.
- **NEVER hand-edit `common-mistakes.md`** — it is generated; the pre-commit generated-file guard blocks a staged copy that diverges from `gen-common-mistakes.sh` output. Edit the record, regenerate.

This is the only place promotion happens at scale. `/log mistake` step 5 merely *flags* an emerging pattern; `/evolve` decides, writes the record, and regenerates.

## Phase 3: Dispatch

For each touchpoint identified, take the right action. Run independent dispatches in parallel where possible.

- **Skill patch** → read and follow `steps/evolve-skill.md` (sibling step file) with the correction context and the skill name. Execute its patch routine inline.
- **New skill** → follow the create-skill procedure (`references/procedures/codex-meta/create-skill/PROCEDURE.md`) with the workflow and trigger description.
- **CLAUDE.md row** → Edit the appropriate table directly. Format: `| <Common Mistake> | <Correct Behavior> |`. Keep entries actionable, specific, generalizable.
- **Agent edit** → Edit the agent's `.md` file directly. Minimal, targeted changes only.
- **Hook / settings** → invoke `/update-config` with the desired enforcement.
- **Durable record (procedure / solution / decision / failure-mode / reference)** → identify the artifact type and invoke the matching record-skill — it owns the write:
  - repeatable multi-step operation → **follow the create-procedure procedure (`references/procedures/codex-meta/create-procedure/PROCEDURE.md`)**
  - situational fix (env / tool / config) → **`/log solution`**
  - non-trivial judgment call to respect later → **`/log decision`**
  - recurring agent-behavior mistake at the ≥3 bar → **`/log failure-mode`** (see Phase 2.5 Step 3)
  - free-form recipe / pattern / knowledge dump → **follow the create-reference procedure (`references/procedures/codex-meta/create-reference/PROCEDURE.md`)**

  Pick by `references/principles/file-directory.md` ("Persistent artifacts table"). Do NOT write these files directly from `/evolve` — the record-skills are the writers; `/evolve` decides which one and when.
- **Mistakes log** → invoke `/log mistake` with the correction details. Do this *first* if a correction occurred — it's cheap and feeds future evolutions.

**Constraints across all dispatches:**
- Don't bloat. If a touchpoint already covers this, update the existing entry instead of adding a new one.
- Don't overfit to a single occurrence. If frequency = 1 and it's a one-off, just `/log mistake` and stop.
- Preserve what works. Patch the smallest surface that fixes the behavior.

## Phase 4: Report

- Correction framed (one sentence)
- Touchpoints patched + rejected (with reason)
- Links/paths to edits

## Final Check

Run TaskList. If any task is not `completed`, finish it now.

## Evolution Log

Append a one-line entry to `~/.claude/references/procedures/codex-meta/evolve/EVOLUTION.md` (create if missing):

```markdown
- YYYY-MM-DD — [brief description of what was evolved and where]
```

## Anti-patterns

- **Surveying without patching** — if you found a real friction, fix at least one surface. Don't write a report and walk away.
- **Patching every surface "just in case"** — pick the minimum set that actually changes behavior next time. CLAUDE.md is not a dumping ground.
- **Skipping /log mistake** — even when the main fix is a skill patch, log the underlying mistake so the JSONL stays the source of truth for the deep-reflect procedure (`references/procedures/research-think/deep-reflect/PROCEDURE.md`).
- **Reinventing the evolve-skill routine** — for skill patches, read and follow `steps/evolve-skill.md`; don't edit the SKILL.md directly from here.
- **Hand-writing a durable record** — `/evolve` orchestrates; it does not write artifact files. Route every procedure/solution/decision/failure-mode/reference through its record-skill (create-procedure procedure `references/procedures/codex-meta/create-procedure/PROCEDURE.md`, `/log solution`, `/log decision`, `/log failure-mode`, create-reference procedure `references/procedures/codex-meta/create-reference/PROCEDURE.md`). Inlining the file write or the `gen-common-mistakes.sh` call duplicates the primitive's logic.
- **Evolving without a real correction** — if Phase 1 can't name a concrete behavior change, stop. Speculative "improvements" belong in a rewrite, not an evolution.
