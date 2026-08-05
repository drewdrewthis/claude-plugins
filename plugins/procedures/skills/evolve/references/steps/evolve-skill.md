---
name: evolve-skill
description: "Improve a skill based on how it just performed. Analyzes conversation for friction, corrections, wasted tokens, and missed steps, then patches the skill. Auto-invoke after any skill completes. Also triggered by the deep-reflect procedure when it identifies skills that were used."
user-invocable: true
argument-hint: "[skill-name] or auto (analyzes current conversation)"
---

# Evolve Skill

Tighten a skill based on real usage evidence. This is not a rewrite — it's a focused patch.

Target skill: $ARGUMENTS (if blank, scan the conversation for the most recently used skill)

## When This Runs

- **Automatically** — at the end of any skill's execution, the invoking Claude should follow the evolve-skill procedure (`references/procedures/codex-meta/evolve-skill/PROCEDURE.md`) as a closing step
- **From the deep-reflect procedure** (`references/procedures/research-think/deep-reflect/PROCEDURE.md`) — when reflection identifies skills that were used in analyzed sessions
- **Manually** — user invokes the evolve-skill procedure (`references/procedures/codex-meta/evolve-skill/PROCEDURE.md`) for a specific skill by name

## Step 0: Track Progress

Before starting, create a task for each phase below using TaskCreate. Chain sequential phases with addBlockedBy. As you work, update each task's status to `in_progress` when starting it and `completed` when done.

## Phase 1: Gather Evidence

First, check `~/.claude/mistakes.jsonl` for entries matching the target skill name. Filter by `"skill":"<target-skill>"` to find structured friction evidence. These entries are high-confidence — they were logged at correction time with classified context.

Then scan the **current conversation** (or session digests if invoked from the deep-reflect procedure) for:

1. **Corrections** — did the user say "no", "not that", "stop", "wrong"? What did the skill get wrong?
2. **Course corrections** — did Claude change approach mid-skill? What forced the pivot?
3. **Missing steps** — did the skill skip something that had to be done ad-hoc?
4. **Redundant steps** — did the skill prescribe steps that were unnecessary or that Claude would do anyway?
5. **Token waste** — verbose instructions, unnecessary reads, redundant context loading?
6. **Friction points** — where did execution slow down, error, or require user intervention?
7. **What worked** — steps that executed cleanly and produced the right result (don't break these)

**Enumerate exhaustively before patching.** Do not stop at the first friction you spot. Re-read the conversation in full, list every distinct friction (numbered), and only then move to Phase 2. A common failure is patching the loudest issue, declaring done, and missing a quieter one in the same turn — forcing the user to re-prompt.

If no friction is found, **do nothing**. Not every usage produces learnings. Say so and stop.

## Phase 2: Diagnose

For each issue found, determine:

- **Root cause** — is this a skill problem or a one-off situation?
- **Frequency signal** — has this happened before? (Check memory for prior evolve-skill findings)
- **Fix type** — add instruction, remove instruction, reword, restructure, or move to references?

Also check for **structural gaps** in the target skill:
- **Task tracking** — if the skill has 3+ sequential phases/steps and no TaskCreate usage, add a "Track Progress" step. Multi-step skills benefit from task visibility.

Only proceed with changes that are:
- **Generalizable** — applies to future invocations, not just this one
- **Net positive** — the fix doesn't make the skill longer/slower without clear benefit
- **Non-destructive** — doesn't break what's already working

## Phase 3: Patch

Read the current SKILL.md. Apply minimal, targeted edits:

| Change Type | Action |
|-------------|--------|
| Missing step | Add it in the right phase, explain why |
| Redundant step | Remove it — the model doesn't need to be told obvious things |
| Wrong instruction | Fix the instruction, add a "Why:" comment if the reasoning is non-obvious |
| Token waste | Trim verbose instructions, move large blocks to references/ |
| Trigger gap | Update the description field if the skill should have triggered but didn't |

**Constraints:**
- Never increase skill length by more than 20 lines in a single evolution
- If the skill is already over 300 lines and needs more, move content to references/
- Preserve the existing structure — don't reorganize unless structure is the problem
- Don't add MUST/NEVER/ALWAYS unless you've tried explaining the reasoning first

## Phase 4: Report

Tell the user (briefly):
- What friction was found (1-2 sentences per issue)
- What was changed (the diff, not the whole file)
- What was left alone and why (if anything was considered but rejected)

## Final Check

Run TaskList. If any task is not `completed`, go back and finish it now.

## Evolution Log

After patching, append a one-line entry to `EVOLUTION.md` in the target skill's directory (create if missing):

```markdown
- YYYY-MM-DD — [brief description of change]
```

Keep the log in the skill's directory but out of SKILL.md itself. The skill definition should contain only instructions, not meta-tracking history.

## Anti-patterns

- **Overfitting** — adding a rule because of one edge case. Wait for a pattern (2+ occurrences).
- **Bloating** — every evolution adds lines, nothing gets removed. Actively trim.
- **Breaking what works** — restructuring a skill that's mostly fine. Patch, don't rewrite.
- **Evolving without evidence** — speculative improvements belong in a rewrite, not an evolution.
