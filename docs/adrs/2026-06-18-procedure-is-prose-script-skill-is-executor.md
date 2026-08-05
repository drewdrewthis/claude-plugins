---
id: dec.2026-06-18-procedure-is-prose-script-skill-is-executor
kind: decision
date: 2026-06-18
keywords: [procedure, skill, hook, taxonomy, executor, prose-script, thin-wrapper, enforced_by, slim, codex-architecture]
links:
  research: [res.2032-self-evolving-procedure]
  decisions: [dec.2026-06-09-procedure-atomic-unit-is-document]
status: active
---
# Taxonomy: procedure = prose script, skill = executor, hook = deterministic enforcement

## Goal
**Stated:** Establish the settled definitional taxonomy for the three codex primitives — procedure, skill, hook — so every subsequent restructuring decision has a named anchor.
**Real:** Close the open question flagged in `res.2032-self-evolving-procedure` ("the 'skill = invokable procedure' taxonomy … whose decision record was REVERTED … treat the taxonomy as an open question"). The owner asserted this taxonomy directly in session on 2026-06-18; recording it stops drift and gives the planned meta-layer slim (`plans/structured-sparking-dusk.md`) a stable base.

## Values protocol
Reversible documentation act on a git-tracked file. No floor/values stakes. Owner asserted the definitions directly — not a candidate for deliberation, only for faithful capture.

## Definitions (owner-stated, load-bearing)

**A procedure is a script in prose.** It exists precisely BECAUSE it cannot be written in code — it needs a judging agent to execute its steps. All code is procedural; a procedure is the prose-resident form of the same thing. Procedures are the single source of truth for workflow CONTENT, reached by reading. Atomic unit = the PROCEDURE.md document (per `dec.2026-06-09-procedure-atomic-unit-is-document`).

**A skill is the executor / invocation handle.** Mental shorthand: `DO X => skill`. A skill is a thin callable wrapper (slash- or chain-invoked): trigger description, arg parsing, consent gates, chain handoffs, plus a single "read and follow `references/procedures/<cat>/<name>/PROCEDURE.md`" instruction. The skill EXECUTES the procedure; it does not contain the workflow content.

**A hook is deterministic enforcement** — the part of a rule that CAN be expressed as code, so it is (a UserPromptSubmit / PreToolUse / Stop hook or a lint pass). Contrast: a procedure is discovered and judged; a protocol is a principle with an `enforced_by:` field naming a hook or lint. A principle doc without `enforced_by:` is aspirational prose — no mechanical consequence if ignored.

**Promotion / demotion:** promotion = a procedure earns a callable name → add a skill wrapper. Demotion = delete the wrapper; the procedure CONTENT never moves. Key property: content and invocation are separable, so the wrapper layer is free to add/remove without breaking any links.

## Chosen path
Accept the owner's definitions as the settled taxonomy. No alternatives were under consideration — this resolves a previously reverted attempt, not an open deliberation.

## Autonomy verdict
decided-by-owner — asserted directly this session, resolves ≥1 prior reverted attempt. Recorded here as `status: active` (not draft): the assertion is grounded, the prior reverted record confirms this was the right framing, the documentation act is reversible.

## Consequences foreseen

**1. Thin-skill rule (the slim criterion)**
A `SKILL.md` that contains workflow CONTENT (the actual steps) rather than a pointer to its `PROCEDURE.md` is bloat. The slim target across all ~66 skills: fat skill → move body to a PROCEDURE.md, leave a thin pointer wrapper. Prior art: git 08687804 ("slim(lead): collapse agent kernel to thin pointers"). Exemplar: `skills/respond/SKILL.md` (23 lines, pure pointer). Counterexample: `skills/investigate/SKILL.md` (135 lines, all workflow content inline — no PROCEDURE.md).

**2. Two guiding principles the codex restructures onto**
- Everything is a procedure (a prose script), and a skill is how you execute one.
- Query-then-discover: find the relevant procedure/principle/mistake/decision by id+name via the router PUSH (`hooks/procedure-router.sh`) + `query-records.sh` PULL, starting at `/respond`.

**3. Meta-layer slim**
This taxonomy is the settled basis for the meta-layer slim planned in `plans/structured-sparking-dusk.md`. Each fat-skill migration follows: (a) move body to `references/procedures/<cat>/<name>/PROCEDURE.md`, (b) replace SKILL.md body with a single pointer line, (c) verify inbound refs still resolve. Migrate-on-touch is the cadence (opportunistic on `/evolve` hits, not a bulk sprint).

## Consequences that materialized
The skill-collapse migration (branch `skill-collapse`, plan `plans/skill-collapse-to-procedures-2026-06-25.md`) executed this taxonomy at scale.

**Collapse outcome — 76 skills → 9 survivors:**
- 4 core skills kept: `how-do-i`, `decide`, `log`, `respond`.
- 5 executor-skills kept: `challenge`, `claude-remote`, `code`, `review-rust`, `test-review` (executor-skills are a permanent category per `dec.2026-06-25-executor-skills-stay`).
- `orchard-start` demoted to a procedure (Option R).
- 67 wrappers deleted: 22 Bucket-A + 40 Bucket-B + the 4 record-writers (`record-decision`/`record-solution`/`record-failure-mode`/`create-procedure` → consolidated into `/log`).
- Discovery is now router + keywords (PUSH router + `query-records.sh` PULL), validated at GATE A: 62/62 live-router 0-miss.

**Learnings the gates surfaced (caught pre-delete — no harm done):**
1. A verbatim skill→procedure move retains intra-body references (step links, templates, EVOLUTION paths, and `/slash` chain-edge dispatches) that must be repointed to the new procedure path — a "move" is not byte-for-byte relocatable.
2. The plan's Phase 5 chain-edge scope was ~30× too narrow: it named 5 procedures, but the corpus actually held ~140 `/slash` dispatches needing rewrite.
3. Executor-skills are a permanent category, not a transitional one (formalized in `dec.2026-06-25-executor-skills-stay`).

## Outcome
Materialized as the skill-collapse migration (see Consequences above). Shipped as a PR against `main`; not yet merged at time of this amendment.

## Process-soundness
[pending]

## Regrets
[pending]
