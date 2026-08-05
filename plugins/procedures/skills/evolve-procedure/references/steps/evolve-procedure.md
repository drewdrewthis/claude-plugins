---
name: evolve-procedure
description: "Improve a procedure based on how it just performed. Analyzes the conversation for friction/deviations/missing-or-broken refs when a procedure was followed, then patches the PROCEDURE.md and logs to its EVOLUTION.md. Triggered after a procedure is followed, or by deep-reflect / the done-gate when a procedure deviation surfaced."
user-invocable: true
argument-hint: "[procedure path or name] or auto (analyzes current conversation)"
---

# Evolve Procedure

Tighten a procedure based on real usage evidence. This is not a rewrite — it's a focused patch.

Target procedure: $ARGUMENTS (if blank, scan the conversation for the procedure that was followed/read this session — the PROCEDURE.md whose steps the turn executed).

## When This Runs

- **Automatically** — after a documented procedure is followed, the invoking Claude should run `steps/evolve-procedure.md` against it as a closing step
- **From the deep-reflect procedure** (`references/procedures/research-think/deep-reflect/PROCEDURE.md`, if this install has one) — when reflection identifies procedures that were used in analyzed sessions
- **From the `am-i-done-gate` review** — when a deviation OR a missing/broken ref surfaced this turn against a documented procedure
- **Manually** — user invokes it to improve a specific procedure

## Step 0: Track Progress

Before starting, create a task for each phase below using TaskCreate. Chain sequential phases with addBlockedBy. As you work, update each task's status to `in_progress` when starting it and `completed` when done.

## Phase 1: Gather Evidence

First, check `~/.claude/mistakes.jsonl` for entries naming the target procedure — grep by its path (`references/procedures/<cat>/<name>/`) or its name. These entries are high-confidence — they were logged at correction time with classified context.

Then scan the **current conversation** (or session digests if invoked from deep-reflect) for:

1. **The procedure being followed** — which PROCEDURE.md drove the turn, and which steps/anchor-sections were executed?
2. **Deviations** — "the doc said X but I did Y." Why did execution diverge from the written step?
3. **Missing steps** — something had to be done ad-hoc that the procedure should have prescribed?
4. **Broken/stale refs** — a path, command, link, or label the procedure points at that no longer resolves or has moved?
5. **Friction / wasted steps** — where did execution slow down, error, double back, or require steps the procedure didn't justify?
6. **What worked** — steps that executed cleanly and produced the right result (don't break these).

**Enumerate exhaustively before patching.** Do not stop at the first/loudest friction you spot. Re-read the conversation in full, list every distinct friction (numbered), and only then move to Phase 2. A common failure is patching the loudest issue, declaring done, and missing a quieter one in the same turn — forcing the user to re-prompt.

If no friction is found, **do nothing**. Not every following of a procedure produces learnings. Say so and stop.

## Phase 2: Diagnose

For each issue found, determine:

- **Root cause** — is this a procedure problem or a one-off situation? A deviation that was *correct for this case but wrong in general* is not a procedure bug.
- **Frequency signal** — has this happened before? (Check the EVOLUTION.md log and memory for prior findings.)
- **Fix type** — add a step, remove a step, reword a step, restructure steps, or fix a stale/broken ref?

Only proceed with changes that are:

- **Generalizable** — applies to future followings, not just this one
- **Net positive** — the fix doesn't make the procedure longer/slower without clear benefit
- **Non-destructive** — doesn't break what's already working

## Phase 3: Patch

Read the current PROCEDURE.md. Apply minimal, targeted edits:

| Change Type | Action |
|-------------|--------|
| Missing step | Add it in the right place, explain why |
| Redundant / wasted step | Remove it — don't prescribe steps the model would do anyway |
| Wrong instruction | Fix it, add a "Why:" comment if the reasoning is non-obvious |
| Broken / stale ref | Repoint the path/command/link/label to the current target |
| Deviation worth codifying | Rewrite the step so next time matches what actually worked |

**Constraints:**
- Patch the smallest surface that fixes the behavior; preserve existing structure unless structure is the problem.
- Don't add MUST/NEVER/ALWAYS unless you've tried explaining the reasoning first.
- Don't overfit to a single occurrence — if frequency = 1 and it's a one-off, log the mistake and stop rather than patching the doc.

Then append a dated line to the **same directory's** `EVOLUTION.md`:

```markdown
- YYYY-MM-DD — <what changed and why, citing the friction>
```

**Multi-procedure docs** (e.g. `fleet-session/lifecycle/PROCEDURE.md` covering launch/continue/stop under anchor-sections) share one `EVOLUTION.md` — note which anchor-section the change touched (e.g. `- 2026-06-09 — lifecycle#launch: …`).

## Phase 4: Report

Tell the user (briefly):
- What friction was found (1-2 sentences per issue)
- What was changed (the diff, not the whole file) and which PROCEDURE.md / anchor-section
- What was left alone and why (if anything was considered but rejected)

## Final Check

Run TaskList. If any task is not `completed`, go back and finish it now.

## Anti-patterns

- **Overfitting** — adding a step because of one edge case. Wait for a pattern (2+ occurrences) or log the mistake instead.
- **Bloating** — every evolution adds lines, nothing gets removed. Actively trim wasted steps.
- **Breaking what works** — restructuring a procedure that's mostly fine. Patch, don't rewrite.
- **Evolving without evidence** — speculative improvements belong in a rewrite, not an evolution.
- **Skipping the EVOLUTION.md log** — the dated line is the audit trail deep-reflect and future evolutions consume; always append it after a patch.
