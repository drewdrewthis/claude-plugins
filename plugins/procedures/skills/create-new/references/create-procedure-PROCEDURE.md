---
id: proc.codex-meta.create-procedure
kind: procedure
date: 2026-06-25
keywords: [create-procedure, codify, new-procedure, procedure-record, repeatable]
links: []
status: active
---

# /create-procedure

Creates a `PROCEDURE.md` + `EVOLUTION.md` pair under `references/procedures/<area>/<name>/`. Consumed via the `keywords` field by `Skill(how-do-i)` → `procedure-scout` and by `scripts/query-records.sh`.

# Triggers

- "We should have a procedure for this"
- "Add this as a procedure" / "codify this"
- Novel multi-step work just succeeded with no matching procedure found
- Post-task retrospective noting a repeatable pattern

## Steps

1. **Grep for an existing procedure first** — never create if one already covers this:

   ```bash
   grep -rl '<2-3 keywords>' ~/.claude/references/procedures/
   ```

   If a match exists, follow the evolve procedure (`references/procedures/codex-meta/evolve/PROCEDURE.md`) to patch the existing one instead — see Boundaries.

2. **Determine `<area>` and `<name>`.** Existing areas: `assistant`, `boxd`, `codex-meta`, `fleet-session`, `git-tree`, `github`, `infra`, `langwatch`, `notify-comms`, `orchardist`, `planner-orchardist-loop`, `provisioning`, `remote`, `research-think`, `review-qa`, `slack`. Pick the closest fit; a new area dir is allowed when none fit.

   - `<name>`: kebab-case slug for the operation (e.g. `record-kanban-card`, `rotate-api-key`)
   - `id`: `proc.<area>.<name>`

3. **Pick keywords** — lowercase, these are the discovery tokens for the procedures hook and skill. Include the operation verb, domain noun, and any common aliases.

4. **Write `PROCEDURE.md`** at `references/procedures/<area>/<name>/PROCEDURE.md`:

   ```
   ---
   id: proc.<area>.<name>
   kind: procedure
   date: <date -u +%Y-%m-%d>
   keywords: [<comma-separated, lowercase>]
   links: {}
   status: draft
   ---
   # <Title>

   ## Steps
   <numbered imperatives>

   ## Flags and Examples
   <optional — include when there are meaningful variations>
   ```

   Status starts as `draft` — creation is cheap and ungated. Promotion to `active` is gated and is NOT this skill's job (see `references/principles/procedure-evolution.md`).

5. **Write `EVOLUTION.md`** in the SAME directory:

   ```
   ---
   id: proc.<area>.<name>.evolution
   kind: procedure
   date: <date -u +%Y-%m-%d>
   keywords: [<same area keywords>]
   links: {}
   status: active
   ---

   # Evolution — <name>

   - <YYYY-MM-DD> — origin: drafted from <one-line provenance — the success/work that motivated it>.
   ```

6. Confirm the two files exist and report: `Created references/procedures/<area>/<name>/PROCEDURE.md (status: draft) + EVOLUTION.md`.

   **Then COMMIT your own scoped paths** — `git add <explicit paths> && git commit`. Do **not** rely on the snapshot timer. As of 2026-07-13 it has not committed anything since 2026-07-08, for two independent reasons, and work left uncommitted is simply lost:
   - `codex-snapshot.timer` is **un-anchored**: it schedules off `OnUnitActiveSec` (monotonic), and `Persistent=true` does nothing for monotonic timers — this box's hibernate/resume drops the anchor, so `systemctl --user list-timers` shows `NEXT = -` even though the unit reports `active`/`enabled`.
   - Even when it does fire, `codex-snapshot.sh` runs `git add -A && git commit`, which the **protected-names pre-commit hook rejects** (the tree carries personal names, incl. a tracked *filename*). The service exits 1 and commits nothing.

   Stage explicit paths (never `-A`, which sweeps other sessions' in-flight work) and keep your own content free of personal names, or the same hook will reject you too.

7. This skill takes <30 seconds. Resume the interrupted conversation.

## Boundaries

- **create-procedure vs evolve / evolve-skill**: This skill is the CREATE half — use it ONLY when no existing procedure covers the work. The evolve procedure (`references/procedures/codex-meta/evolve/PROCEDURE.md`) and evolve-skill procedure (`references/procedures/codex-meta/evolve-skill/PROCEDURE.md`) operate on EXISTING procedures/skills after they hit friction (the PATCH/PROMOTE loop). If a procedure already exists, stop here and follow the evolve procedure. Authority: `references/principles/procedure-evolution.md`.
- Do NOT set `status: active` on a new record — that requires a promotion gate.
- Do NOT run this skill for skills (`SKILL.md` files) — that is the create-skill procedure (`references/procedures/codex-meta/create-skill/PROCEDURE.md`).
- No codebase reading, no implementation — prose record only.
