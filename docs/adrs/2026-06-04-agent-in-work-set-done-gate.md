---
id: dec.2026-06-04-agent-in-work-set-done-gate
kind: decision
date: 2026-06-04
keywords: [hook-design, done-gate, delegation, false-negative, no-change-decision]
links: {}
status: pending
situation_tags: [hook-design, done-gate, delegation, false-negative, no-change-decision]
resolve_after: 2026-06-18
---
# Keep `Agent` in the done-gate WORK set; converge via verification-only sweeps

## Goal
Stated: should `Agent` move out of the done-gate-stop.sh WORK set (like Bash) so a
delegation-first agent's streak stops capping at 1 ("Pass 1 of 3" forever)?
Real: gate **fidelity** — the successive-streak must mean "passes since the last
mutation that still needs verifying." The question is whether Agent-resets miscounts.

## Values protocol
reversibility-weighted high (hook change is a 1-line revert) · structural horizon
(fleet-wide always-loaded Stop hook) · floor test is hard gate: an undone delegating
agent must NOT slip through · correctness > convenience.

## Chosen path
**No hook change.** Keep `Agent` in WORK (it resets the streak). Resolve the
"Pass 1 forever" symptom by WORKFLOW: a delegating agent's final convergence passes
must be **verification-only** — Bash (re-run tests), Read (re-read evidence),
TaskList — with NO Agent call. Bash/Read/Task* are non-resetting, so the streak
then climbs 1→2→3 and releases. Document the interaction (this file + a solution doc).

## Autonomy verdict
decided-and-acted (reversible non-change + docs; no human escalation warranted).

## Consequences foreseen
- The decisive fact (verified against this session's real transcript): a delegated
  mutation appears in the PARENT transcript ONLY as `Agent` — Edit/Write/NotebookEdit
  count = 0, Agent count = 3. The subagent's actual Edits live in the subagent's
  transcript, which the hook never reads. So removing Agent from WORK would mean a
  delegated FILE MUTATION no longer resets the streak → undone work ships as done.
  That fails the floor test. Candidate REJECTED.
- Empirically confirmed both branches with fixtures against the real hook:
  - Agent between every block (the lead's pattern) → BLOCK forever (streak caps at 1).
  - Bash-only sweeps between blocks → RELEASE (streak climbs to 3).
- Reframe: "Pass 1 forever" was the gate working AS DESIGNED. Calling Agent every
  sweep = producing NEW work every sweep = genuinely not converged. The gate
  correctly refuses to release while you keep delegating new work.

## Consequences that materialized
[pending — resolve_after 2026-06-18: did framing the convergence-via-verification
rule prevent the next delegating agent from grinding to the 12-fire ceiling?]

## Outcome
[pending]

## Process-soundness
[pending — the empirical check (does parent record subagent edits?) was the load-
bearing step; without it the "just move Agent to non-resetting" path looked correct
and would have opened a false-negative. Decomposition before edit earned its keep.]

## Regrets
[pending]
