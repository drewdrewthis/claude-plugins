---
id: proc.codex-meta.create-reference
kind: procedure
date: 2026-06-25
keywords: [create-reference, reference-doc, durable, recipe, pattern, knowledge-dump]
links: []
status: active
---

# /create-reference

Creates a reference doc at `references/<area>/<name>.md` (or `references/<name>.md` for top-level files). Consumed by skills and agents that link to it for durable knowledge. Discoverable via `query-records.sh` and keyword grep.

# Triggers

- "Add a reference for this" / "document this pattern" / "write a reference doc on X"
- Research just completed whose findings should survive session end
- A skill or procedure needs a stable target to link to
- A policy or principle needs a home outside `CLAUDE.md`

## Steps

1. **Determine `<area>` and `<name>`.** Existing areas under `references/`: `adrs`, `decisions`, `failure-modes`, `mandates`, `plans`, `policies`, `principles`, `procedures`, `research`, `scenarios`, `solutions`. Plus many top-level `references/<name>.md` topic files. Pick the closest fit; a new area dir is allowed when none fit — create the dir.

   - Area fit guide: `principles/` for behavioral rules; `policies/` for constraints/mandates; `research/` for findings/analysis; `procedures/` only if creating a PROCEDURE.md (use the create-procedure procedure `references/procedures/codex-meta/create-procedure/PROCEDURE.md` instead); top-level `references/<name>.md` for broad cross-cutting topics.
   - `<name>`: kebab-case slug (e.g. `orchard-daemon`, `model-selection`, `session-spawn-recipe`)
   - `id`: `ref.<area>.<name>` for area files; `ref.<name>` for top-level files

2. **Grep for overlap** before writing:

   ```bash
   grep -rl '<2-3 keywords>' ~/.claude/references/
   ```

   If a near-match exists, consider extending it (Edit) rather than creating a new file.

3. **Write the record** at the resolved path:

   ```
   ---
   id: ref.<area>.<name>
   kind: reference
   date: <date -u +%Y-%m-%d>
   keywords: [<lowercase — discovery tokens, synonyms, related tools>]
   links: {}
   status: active
   ---
   # <Title>

   ## <Section>
   <content>

   ## <Section>
   <content>
   ```

   Body is free-form. Use `## ` section headers for scanability. Lead with the conclusion or most-referenced fact. Prefer tables for 2+-dimensional content.

4. **INDEX row — conditional.** Most `references/<area>/` dirs have NO `INDEX.md`; do NOT create one. Dirs that do: `solutions/`, `scenarios/`, `decisions/`, `plans/`. For `decisions/` and `solutions/`, the INDEX is GENERATED — never hand-append; just run `scripts/gen-decisions-index.sh` or `scripts/gen-solutions-index.sh` after adding the record file. For `scenarios/` and `plans/`, append a row at the TOP of the table (newest-first) — those remain hand-maintained.

5. Confirm the file path and report. Resume the interrupted conversation.

## Boundaries

- This skill is for FREE-FORM reference docs — not procedures (use the create-procedure procedure `references/procedures/codex-meta/create-procedure/PROCEDURE.md`), not solution fixes (use `/log solution`), not failure-mode records (use `/log failure-mode`), not decision records (use `/log decision`).
- Do NOT create an `INDEX.md` in a dir that lacks one — only append (or regenerate, for `decisions/`/`solutions/`) when one already exists.
- Never hand-edit `references/decisions/INDEX.md` or `references/solutions/INDEX.md` — rerun the generator script instead.
- `status: active` always at creation (unlike procedures which start `draft`).
- Keep the doc scannable: lead with conclusion, use headers, avoid prose blocks where a table works.
- No INDEX row for `principles/`, `policies/`, `research/`, `adrs/` — those dirs have no INDEX.md.
