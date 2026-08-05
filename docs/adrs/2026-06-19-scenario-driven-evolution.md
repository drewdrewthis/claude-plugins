---
id: dec.2026-06-19-scenario-driven-evolution
kind: decision
date: 2026-06-19
keywords: [scenario-driven, evolution, procedure, scenario, worktree, test-driven, capture-format, premature-crystallization, corrective-loop]
links:
  decisions: [dec.2026-06-18-procedure-is-prose-script-skill-is-executor]
  research: [res.2037-generative-procedure-evolution, res.2032-self-evolving-procedure]
  principles: [prin.procedure-evolution]
status: active
---
# Scenario-driven evolution: behavioral/corrective changes start with a scenario, not a procedure edit

## Goal
**Stated:** Establish that the DEFAULT path for behavioral/corrective procedure evolution is to capture a scenario first, not to author or edit a procedure doc.
**Real:** The existing principle (`prin.procedure-evolution`) describes a generative success-crystallization loop and a gated promotion norm but says nothing about HOW corrective changes are triggered. The owner asserted this trigger doctrine directly in session on 2026-06-19; recording it stops drift and gives the corrective loop a concrete, parallelizable shape.

## Values protocol
Reversible documentation act on a git-tracked file. Owner asserted the doctrine directly. Not a deliberation candidate — faithful capture only.

## Doctrine (owner-stated, load-bearing)

**Scenario-driven evolution.** Evolution of BEHAVIORAL or CORRECTIVE changes starts by capturing the situation as a NEW or UPDATED SCENARIO — not by hand-authoring or editing a procedure first. The scenario is the unit of evolution: the red test. Then, in a SEPARATE worktree/branch, work happens to get that scenario to pass as cleanly as possible. The procedure change FALLS OUT of making the scenario green, rather than being written up front.

> "New problems/procedures become uncovered scenarios that need to be optimized for."

**The capture format (the ergonomic win).** A new scenario is cheap: record the situation, the failure modes encountered, the actions the agent took, and the traps/confusion hit while trying to do the right thing. Mental model: "I came across a new scenario, this is what I did, this is what I did wrong while trying to do right (traps, confusion)." That JSON intake is far lower-friction than authoring a procedure doc, and it DEFERS the hard design work to the worktree that optimizes it.

**The boundary.** Two lanes, chosen by whether there is a behavior to prove:

| Change type | Lane |
|---|---|
| Behavioral / corrective — a mistake, trap, confusion, a behavior to assert | Scenario-first → worktree optimizes green → procedure edit follows |
| Pure factual / mechanical — a renamed CLI flag, a moved path — no agent behavior to assert | Direct procedure edit |

## Rationale

1. **Test-driven shape.** The scenario is the red test; the procedure edit is whatever makes it green. Same shape as TDD: write the assertion first, then make the code satisfy it. The procedure cannot crystallize prematurely because it is not written until the scenario is green.

2. **Structurally kills premature crystallization (res.2037 FM-3).** You cannot crystallize doctrine from N=1 because you are not writing doctrine in the capture step — you are writing a SITUATION. Generalization happens in the optimize-it-green step, with the scenario as the falsifiable target. The gated draft→active norm (`prin.procedure-evolution`) still governs the procedure side, but the TRIGGER is now a failing/uncovered scenario, not a logged-mistake-then-author.

3. **Matches the skill=executor taxonomy (dec.2026-06-18).** A skill runs a procedure like a script; a scenario asserts the script produced the right behavior; evolution = add an assertion, then fix the script. The scenario/criterion layer in `res.2032-self-evolving-procedure` is precisely this empirical assertion layer.

4. **Parallelizable by construction.** Capture is instant, on the main branch, no worktree needed. Optimization is isolated worktree/branch work that can proceed in parallel with other sessions.

## Aside: skill = human-invokable too

The owner noted: a skill is HUMAN-invokable (not only chain-invoked) — "it's like if I were running a script; I'd expect the underlying procedure to be followed." This refines but does not change the 2026-06-18 taxonomy. Skill = executor, whether the invoker is a human or another agent.

## Chosen path
Accept the owner's doctrine as the settled corrective-evolution trigger. The generative loop (`prin.procedure-evolution`) and the gated promotion norm (`res.2037`) are unchanged; this decision specifies the STARTING POINT of the corrective lane.

## Autonomy verdict
decided-by-owner — asserted directly this session. Documentation act is reversible. Recorded as `status: active`.

## Consequences foreseen

**1. `references/principles/procedure-evolution.md` amendment needed.**
The principle currently describes only the generative (success-crystallization) loop. It must be amended to make scenario-first the default corrective trigger path: a mistake or trap → capture scenario (situation + failure-modes + actions + traps, `verification: pending`) → worktree optimizes it green → procedure edit + promotion follow. The draft→active gating norm remains unchanged; what changes is that the TRIGGER is now an uncovered scenario, not a raw authored procedure.

**2. `/evolve` Phase 2.5 wiring shape (plans/structured-sparking-dusk.md Phase E).**
A new mistake → CAPTURE a scenario marked `verification: pending` → a worktree optimizes it green → procedure edit + promotion follow. The promotion gate (res.2037: pending→live only after a second distinct session confirms) still holds. The scenario capture is the new Phase 2.5 output; the worktree optimization is the new Phase 3 trigger.

**3. Primary self-improvement loop reference.**
This is the codex's primary self-improvement loop. It should be referenced from `references/principles/codex-operating-model.md` as the canonical corrective lane, alongside the reactive mistake-tracking loop.

## Corollary: the corpus globally tightens the bar

**The corpus globally tightens the scenario bar.** The codex records — failure-modes, common-mistakes, principles, decisions, solutions — accumulate CONTINUOUSLY and WITHOUT a PR/gate. Because a scenario is a SITUATION graded against the CURRENT corpus (not a frozen assertion), recording a new mistake / principle / decision / solution can suddenly make a whole GROUP of previously-green scenarios fail at once — every scenario whose situation touches the newly-recorded norm is now judged against the stricter standard.

**This is the system working, not a regression.** A red that appears because the bar rose is the HEALTHY signal: the scenarios are correctly reporting that the codex no longer clears its own new standard. The reds become a free WORKLIST — the act of recording a norm generates the set of situations that must now be optimized to clear it. The response to such a red is to make the agent clear the new bar (optimize it green in a worktree — the scenario-driven loop), NOT to suppress or soften the scenario.

**Two directions, two cost profiles:**

| Direction | Cost | Gate |
|---|---|---|
| records → scenarios (bar tightening) | Automatic, ungated, cheap, constant — happens just by recording a norm | None |
| scenarios → green (clearing the bar) | Deliberate worktree work — this is where effort goes | Worktree / optimize |

**Critical discriminator for verification.** A previously-green scenario going red has TWO possible causes that must be distinguished:

1. **The bar rose** — a principle/record was tightened/added. GOOD. Optimize the agent to clear it.
2. **Contract was dropped** — a doc lost a load-bearing clause (e.g. an over-aggressive slim). BAD. Restore the clause.

The discriminator is the DIFF: did a principle/record tighten (cause 1), or did a doc lose a clause (cause 2)? Verification after any codex edit must ask which — never assume "red = regression."

## Consequences that materialized
[pending]

## Outcome
[pending]

## Process-soundness
[pending]

## Regrets
[pending]
