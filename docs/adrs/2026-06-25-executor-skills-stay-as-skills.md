---
id: dec.2026-06-25-executor-skills-stay
kind: decision
date: 2026-06-25
keywords: [skill, executor, procedure, demotion, taxonomy, carve-out, thin-wrapper, no-twin, dispatch, agent, skill-collapse]
links:
  decisions: [dec.2026-06-18-procedure-is-prose-script-skill-is-executor]
  plans: [plan.skill-collapse-to-procedures-2026-06-25]
status: active
---
# Executor-skills stay as skills — they are not demotable

## Goal
**Stated:** Decide what happens to the 5 skills that GATE A of the skill-collapse found have NO procedure twin and no prose body to move — **challenge, claude-remote, code, review-rust, test-review**.
**Real:** Close the partition defect that GATE A surfaced. The collapse plan's working assumption was that EVERY non-survivor skill is a prose-content wrapper whose body relocates to a `PROCEDURE.md`. These 5 broke that assumption: the partition would have either left them unbucketed (silent `git rm`) or forced an empty stub procedure that the router could never meaningfully surface.

## Context — what GATE A found
The skill-collapse entry gate (`plans/skill-collapse-to-procedures-2026-06-25.md` §Phase 0) requires that every Bucket-A skill resolve to an on-disk `references/procedures/<cat>/<name>/PROCEDURE.md` twin via the live `procedure-router.sh`. Five Bucket-A entries had no twin to resolve to. Inspecting them showed WHY: none contains workflow prose. Each is a thin callable executor that does one thing — dispatch:

| Skill | What it dispatches |
|---|---|
| `challenge` | invokes the `devils-advocate` agent on a proposal |
| `code` | invokes the `coder` agent with a feature/requirements brief |
| `review-rust` | invokes the Rust review agents (rust-reviewer + uncle-bob + test/pii reviewers) |
| `test-review` | invokes the `test-reviewer` agent on specs/tests |
| `claude-remote` | toggles claude-remote Bash-offload mode for the session (script/state flip) |

## Decision — the carve-out
**Thin executor-skills that dispatch an agent or flip a script/session mode STAY as skills. Only PROSE-CONTENT skills collapse to procedures.**

This follows directly from the anchor taxonomy (`dec.2026-06-18-procedure-is-prose-script-skill-is-executor`):
- A **procedure** is *a script in prose* — it is the single source of truth for workflow CONTENT, reached by reading.
- A **skill** is *the executor / invocation handle* — a thin callable wrapper (trigger description, arg parsing, consent gates, chain handoff) whose only body, in the prose-content case, is a single "read and follow `…/PROCEDURE.md`" pointer.
- **Demotion = delete the wrapper; the CONTENT moves to a procedure.** The mechanism presupposes there IS prose content to move.

For these 5, there is **no prose content to move** — the "step" is a single dispatch, which is the executor's whole reason to exist. A procedure twin would be an empty shell that adds an indirection hop and gives the router nothing distinctive to rank. So they are **not demotable**; demoting them would be a category error, not a slim.

They therefore form a **permanent "executor-skills (kept)" category**: a recognized, stable third outcome of the collapse partition alongside (A) wrapper-deletes and (B) content-moves.

## Boundary — what this does NOT cover
- **`review`** is NOT in this carve-out. It has a fat, multi-step workflow body (parallel principles/hygiene/test/security/proof reviews + a durable verdict-comment protocol) — that is prose content, so it converts to a procedure like every other Bucket-B skill. Having an agent-ish name is not the test; **carrying no prose content** is.
- The test for membership is **"is the body a single dispatch with no workflow prose to relocate?"** — not "does it call an agent." A skill that orchestrates several agents through judged steps (like `review`) is prose content and demotes.

## Values protocol
Reversible documentation + taxonomy-application act on git-tracked files. No floor/values stakes. This applies an already-settled owner taxonomy (dec.2026-06-18) to a newly-surfaced case; it does not establish new policy, only names a category the taxonomy already implies.

## Autonomy verdict
decided-by-rule — the anchor taxonomy already determines the outcome (no prose content ⇒ nothing to demote ⇒ stays a skill). Recorded `status: active`: grounded in dec.2026-06-18, surfaced by a concrete gate failure, fully reversible.

## Consequences
- **Plan partition amended:** Bucket A 27→22; survivors/specials 8→13; the 5 move A→survivors. AC-0.0 (closure list) and AC-6.1 (survivor SET, no longer a bare "==4") updated to include them as kept survivors.
- **Survivor headline changes:** the collapse is no longer "exactly 4 survivors." It is 4 core survivors + the kept executor-skills + a conditional `orchard-start`. The real win is unchanged: ~62 prose-content wrappers removed + the 23-twin duplication killed.
- **Future skills:** a new skill that is a pure agent/script dispatch is born as a permanent executor-skill, not a migration candidate. `/evolve` and the collapse cadence should not flag executor-skills as "fat skills to slim."

## Outcome
[pending — materializes when the skill-collapse Phases 1–6 land]

## Regrets
[pending]
