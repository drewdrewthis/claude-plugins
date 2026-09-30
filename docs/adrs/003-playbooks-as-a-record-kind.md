# ADR-003: Playbooks as a distinct record kind

**Status:** Proposed. Fleet usage produced a fourth artifact shape that ADR-001's taxonomy doesn't claim.

## The problem

ADR-001 defines three record kinds: procedure (prose script, single goal, read whole, retrieved per-task by the how-do-i gate), skill (invocation gateway), and hook (deterministic enforcement). Real usage across a fleet of agents produced a fourth kind that fits none of these cleanly.

Concretely: a domain operating playbook was written for tenant assistant agents covering how to run a task-management system on a tenant's behalf — not a single how-do-I-do-X procedure, but a whole domain's worth of philosophy, routines, and judgment calls. Because no record kind claims this shape, it got stored as a loose workspace note, outside the retrieval and evolution machinery every other record kind gets for free.

## Procedure vs playbook

A procedure answers "how do I do X right now without stepping on a rake": one goal, executable steps, a verification step, known traps. It's tactical and meant for mid-task lookup — exactly the shape the how-do-i gate is built to retrieve.

A playbook is operating doctrine for a whole domain, not a single task. It typically bundles:

- **Philosophy** — the operating principle for the domain (e.g. "the task board is the single system of record").
- **Rhythms** — recurring routines, like a daily brief or a periodic board review.
- **Judgment calls** — guidance for decisions that don't reduce to steps (e.g. when to set a due date).
- **A bundle of tactics** — pointers to the procedures that cover the mechanics.

Playbooks are outcome- and user-centered; procedures are tool-centered.

The structural difference that matters most is retrieval semantics. A procedure is pulled per-task, on demand, by the gate. A playbook is read whole, up front, *before* working in a domain — on agent provisioning, on tenant onboarding, or on first entry into a domain an agent hasn't operated in before. It's onboarding material, not mid-task lookup, and treating it as gate-retrieved would be the wrong retrieval shape even if the content were otherwise fine.

Playbooks compose procedures rather than duplicate them. A line like "run the board-review rhythm" should point at a small procedure that covers the mechanics of that review, rather than restating the mechanics inline. Doctrine lives in the playbook; rakes live in procedures. This keeps the two from drifting against each other — a mechanic that changes only needs updating in one place.

## Decision (proposed)

Add `playbooks/` as a record category alongside `procedures/` in a knowledge store, following the same shape:

- Path: `references/playbooks/<domain>/PLAYBOOK.md`.
- Same six-key frontmatter as other record kinds, with `kind: playbook`.
- A companion `EVOLUTION.md`, matching what procedures already carry, so playbooks get the same amendment history and drift tracking.

Playbooks are tenant-agnostic — a playbook describes how to operate in a domain generically, not how a specific tenant deployment happens to be configured. Where a playbook needs to reference concrete steps, it links to a procedure by id instead of restating steps inline.

Retrieval mechanism is deliberately left open in this ADR: loading happens on domain entry or provisioning, not per-task. That could be a provisioning step, a skill invocation, or a CLAUDE.md pointer for the relevant agent role — whichever mechanism a given fleet already uses to onboard an agent into a domain. This ADR fixes the record kind and its shape, not the loader.

Existing playbook-shaped documents that were stored as loose notes should migrate into this structure. Sections of an existing playbook that are actually procedure-shaped — for example, a verified list of API traps — should over time be extracted out into procedures the playbook then references, rather than living inline as doctrine.

## What this is not

This is not a rewrite of ADR-001's gate design. The how-do-i gate continues to retrieve procedures only; playbooks are not added to its retrieval set.

This is not a marketplace or index feature. Playbooks follow the same document-is-the-atomic-unit rule as procedures — one file, one domain, no cross-file composition beyond linking by id.

## Consequences

- A fourth record kind to maintain, with its own frontmatter conventions and evolution file to keep current.
- A clear, structured home for domain-doctrine documents that were previously scattered as loose workspace notes with no retrieval or amendment discipline.
- Ongoing extraction pressure in both directions: procedure-shaped content gets pulled out of playbooks into procedures, and playbooks stay free to describe philosophy and judgment without turning into trap-lists; procedures stay free to stay tactical without turning into essays.
