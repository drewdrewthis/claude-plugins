---
id: prin.procedure-evolution
kind: principle
date: 2026-06-14
keywords: [procedure, evolution, generative, draft, promote, crystallize, skill-library, novel, reuse]
links: { research: [res.2037-generative-procedure-evolution] }
status: active
enforced_by: none-aspirational
title: Procedure evolution (generative loop)
purpose: When novel work succeeds and no procedure covered it, capture a cheap draft procedure; it earns promotion to active only on a sharp gate. Sibling to the reactive mistake loop.
---

# Procedure evolution (generative loop)

**Corrective / behavioral changes** (a mistake, trap, confusion) are scenario-driven: capture a failing scenario first, optimize it green in a worktree, then let the procedure edit fall out of that — see `references/decisions/2026-06-19-scenario-driven-evolution.md`. The generative loop below governs SUCCESS crystallization only.

Novel work that worked, with no existing procedure → draft a procedure for the next agent; promote on a gate, not on the first success.

## Create-trigger

Novel work succeeded AND no existing procedure applied → capture a `status: draft` procedure at `references/procedures/<cat>/<name>/PROCEDURE.md` plus a co-located `EVOLUTION.md` seeded with an origin line. Creation is cheap, ungated, reversible (delete with no ceremony). The gate is on PROMOTION, not creation. Conform to the atomic-unit decision (`references/decisions/2026-06-09-procedure-atomic-unit-is-document.md`): one dir = one PROCEDURE.md + EVOLUTION.md.

## Draft vs active

A `draft` is a candidate from a single success (N=1) — NOT doctrine: unproven, freely deletable, and surfaced-but-tagged by the router (shown as the best available guidance for novel work, marked "(draft — unproven)" so it cannot masquerade as proven doctrine; it is NOT suppressed). An `active` procedure is proven and authoritative. The marker is the frontmatter `status:` line.

## Promotion gate

Promote `draft`→`active` iff at least ONE gate below fired ON A TURN OTHER THAN the draft-creating turn, AND the promotion commit records the gate token plus its pointer in `EVOLUTION.md`. Absent a fired gate, the draft stays `draft` indefinitely — that is NOT a failure.

- **Gate 1 — second independent success:** procedure followed to drive a DISTINCT goal (not a re-attempt of the origin goal in a new session) that succeeded. Evidence: `EVOLUTION.md` line `gate: second-success` + the distinct task ref (issue#/SHA).
- **Gate 2 — verification on a non-origin turn:** steps run against their PRODUCTION target (not mock/dry-run/code-read) on a later turn, producing the asserted effect. Evidence: `gate: verification` + a disconfirming-capable observation (output/artifact/scenario-id that would be ABSENT had the steps not worked). "Ran it, worked" does NOT fire it.
- **Gate 3 — reactive-loop convergence:** a logged mistake with ≥3 total occurrences resolved by following this procedure. Evidence: `gate: reactive-convergence` + the mistakes.jsonl id(s).

Evidence-shape for a valid promotion: a git commit flipping exactly one frontmatter line (`status: draft`→`active`) AND, in the SAME commit, an `EVOLUTION.md` dated line carrying a parseable `gate:` token plus that gate's pointer. A status-flip with no co-committed gate line, or a token without its pointer, is a MALFORMED promotion and fails.

## Demotion (symmetry)

An `active` procedure is not frozen: a failed application, or becoming the `recurrence_of` root of a new mistake, reverts it toward `draft`/`superseded`, recorded in `EVOLUTION.md`.

## Relationship to the patch loop

After promotion, ongoing tightening is the existing `skills/evolve/steps/evolve-procedure.md` after-use patch. This principle owns CREATE + PROMOTE; evolve-procedure owns PATCH.

## Done-gate

Following a `draft` procedure satisfies the done-gate's "did you follow a documented procedure" check (`WHAT_DONE_LOOKS_LIKE.md`). Following a draft for a second distinct goal is precisely Gate-1 evidence, so the done-gate naturally feeds promotion.
