---
id: proc.codex-meta.evolve-skill
kind: procedure
date: 2026-06-25
keywords: [evolve-skill, improve-skill, patch-skill, friction, correction, skill-patch]
links: []
status: active
---

# /evolve-skill

Target skill: $ARGUMENTS (if blank, scan the conversation for the most recently used skill)

Invocation contexts: auto at skill close, from the deep-reflect procedure (`references/procedures/research-think/deep-reflect/PROCEDURE.md`) on analyzed sessions, or manually by name via this procedure.

See `references/principles/procedure-evolution.md` for the broader evolution contract.

## Steps

1. **Gather evidence.** Check `~/.claude/mistakes.jsonl` for `"skill":"<target-skill>"` entries — high-confidence, logged at correction time. Then scan the current conversation (or session digests if from the deep-reflect procedure, `references/procedures/research-think/deep-reflect/PROCEDURE.md`) for: corrections ("no"/"wrong"/"stop"), mid-skill pivots, missing steps done ad-hoc, redundant prescribed steps, token waste (verbose reads, redundant context loads), friction points, and what worked cleanly. If no friction found, say so and stop — not every usage produces learnings.

2. **Diagnose.** For each issue: is it a skill problem or a one-off? Has it recurred? (Check memory for prior evolve-skill findings.) Fix type: add, remove, reword, restructure, or move to `references/`. Also check structural gaps — if the skill has 3+ sequential steps and no TaskCreate usage, add a task-tracking step. Only proceed with changes that are generalizable, net-positive, and non-destructive.

3. **Patch.** Read the current SKILL.md. Apply minimal targeted edits:

   | Change type | Action |
   |-------------|--------|
   | Missing step | Add in the right place; WHY clause only if removing it causes wrong behavior |
   | Redundant step | Remove — don't tell the model obvious things |
   | Wrong instruction | Fix; add inline WHY only when removal causes a wrong result |
   | Token waste | Trim verbose instructions; move large blocks to `references/` |
   | Trigger gap | Update the `description` frontmatter field |

   Constraints: never grow the skill by more than 20 lines in one evolution; if already >300 lines and needs more, move content to `references/`; preserve existing structure unless structure is the problem; don't add MUST/NEVER/ALWAYS without trying a reasoned explanation first.

4. **Report.** What friction was found (1–2 sentences per issue), what changed (diff, not full file), what was considered but rejected and why.

5. **Log.** Append one line to `EVOLUTION.md` in the skill's directory (create if missing):
   ```
   - YYYY-MM-DD — [brief description of change]
   ```
   The skill file carries only instructions; meta-tracking history lives in EVOLUTION.md.

## Boundaries

- Overfitting: don't add a rule for a single edge case — wait for 2+ occurrences.
- Bloating: every evolution must remove something or the net change must be zero lines.
- Rewrite creep: patch don't restructure a skill that's mostly working.
- Speculation: no changes without evidence from the current conversation or mistakes.jsonl.
