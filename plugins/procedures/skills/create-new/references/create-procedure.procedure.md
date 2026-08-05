---
id: proc.codex-meta.create-procedure
kind: procedure
date: 2026-06-25
keywords: [create-procedure, codify, new-procedure, procedure-record, repeatable]
links: []
status: active
---

# /create-procedure

Creates a `PROCEDURE.md` + `EVOLUTION.md` pair under `references/procedures/<area>/<name>/`. Consumed via the `keywords` field by `Skill(how-do-i)` → `procedure-scout` and by `scripts/query-records.sh` at the plugin root (the invoking skill's prompt carries the resolved path).

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

   If a match exists, patch that procedure directly (and log the change in its sibling `EVOLUTION.md`) instead of creating a new one — see Boundaries.

2. **Determine `<area>` and `<name>`.** List the existing areas — never work from a remembered list:

   ```bash
   ls "${CODEX_ROOT:-$HOME/.claude}/references/procedures/"
   ```

   Pick the closest fit; a new area dir is allowed when none fit.

   - `<name>`: kebab-case slug for the operation (e.g. `record-kanban-card`, `rotate-api-key`)
   - `id`: `proc.<area>.<name>`

3. **Pick keywords** — lowercase, these are the discovery tokens for the procedures hook and skill. Include the operation verb, domain noun, and any common aliases.

4. **Write `PROCEDURE.md`** at `references/procedures/<area>/<name>/PROCEDURE.md`, from `skills/log/templates/procedure.template.md` at the plugin root:

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

   Status starts as `draft` — creation is cheap and ungated. Draft-then-promote: a first success earns a draft, and promotion to `active` happens only after the procedure has been followed as written and worked. That promotion is NOT this skill's job.

5. **Write `EVOLUTION.md`** in the SAME directory, from `skills/log/templates/evolution.template.md` at the plugin root:

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

   Then commit your own explicit paths (never `git add -A` — it sweeps other sessions' in-flight work).

7. This skill takes <30 seconds. Resume the interrupted conversation.

## Boundaries

- **Create vs patch**: This skill is the CREATE half — use it ONLY when no existing procedure covers the work. Patching an EXISTING procedure or skill after it hits friction is out of scope: edit the artifact directly and append the dated line to its `EVOLUTION.md`. If a procedure already exists, stop here and do that instead — `/evolve-procedure` owns the patch lane.
- Do NOT set `status: active` on a new record — that requires a promotion gate.
- Do NOT run this skill for skills (`SKILL.md` files) — that is the create-skill procedure (`create-skill.procedure.md`).
- No codebase reading, no implementation — prose record only.
