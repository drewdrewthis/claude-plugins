---
id: prin.coding
kind: principle
date: 2026-06-12
keywords: [coding, solid, tdd, bdd, standards, simplest-explanation]
links: {}
status: active
title: Coding Standards
purpose: Priority-ordered design principles, testing stance, doc conventions, and model-knowledge rules.
---

# Coding Standards

## Design principle priority

**SOLID > CUPID > Clean Code > KISS > YAGNI**

Apply in order: when principles conflict, higher-priority wins. Do not gold-plate past what tests and requirements demand (YAGNI is the floor-cap).

## Testing

**BDD + TDD.** Tests drive implementation, not the reverse.
- Write the test first; write the minimum production code to pass it.
- Feature behavior lives in BDD feature files; unit coverage via TDD red-green-refactor.

**Test doubles.** Don't mock what you own. Prefer a fake (in-memory impl — fake repo, fake clock) over a mock. Assert on emitted behavior/artifacts, not call-sequences (`verify(x).calledWith(...)`). Mock only at a boundary you can't cheaply/safely/deterministically call — network, paid/rate-limited APIs, clock, randomness, destructive or not-yet-built deps. Many doubles to test one unit → coupling smell; fix the unit. See [[acceptance-criteria]] (encoding it as a gated+ungated AC pair), [[done-means-verified]] (contract-masking trap), [[2026-06-10-synthetic-tool-receipt-not-a-mock]] (where the line sits).

## Documentation

- **Public APIs get doc comments** — every exported function, class, and type.
- **Comments explain WHY, not WHAT.** What is in the code; why is context the code cannot carry.
- No restating what the code does in prose. If a comment describes the what, delete it.

## Boy Scout rule

If you diagnose a smell in a file you are already editing, and the fix is:
- Small (fits in the same commit without scope creep)
- Contained to that file

→ Fix it in the same commit. "Pre-existing" is not a shield.

Do NOT let boy-scout scope balloon into a refactor — small + in-file is the constraint.

## Model knowledge

Trust the operator's named model ID. Do not assert a model "doesn't exist" from training-data knowledge.

Verify existence and capabilities via `/v1/models` API, not memory.

Full rules and edge cases: `references/model-knowledge.md`.

## Act-gate — the cheap disconfirming check fires BEFORE the irreversible-ish act

A claim that drives an irreversible-ish action (file an issue/DECISION, launch a worker, dispatch a coder, hand back "blocked") must first run its ONE cheap disconfirming check this turn. Four trigger shapes, each with its matching check:

| Claim shape | Cheap disconfirming check (run BEFORE the act) |
|---|---|
| **Blames a dependency / own-input bug** | Diff the observed data against the spec/plan that PRODUCED it. Blame your own input (script, config, args) LAST — applies to diagnosis, not just action. |
| **A component can't-do-X** | Read the consumer's FULL input path and quote the line that would carry X. For a compile/build can't-do-X: compile a trivial probe and inspect the toolchain (each interpreter's sysconfig, the linker) — a stale baked SDK in one venv is not "the platform can't build it." |
| **A measurement is the deployable number** | Benchmark the artifact that actually SHIPS (the slim/pipx/production build), not a convenience build (`[all]` uv-venv, dev image). A number measured on a non-shipping build is not a deployable result. |
| **Work is blocked / needs-a-live-session** | "Blocked" carries the same evidence bar as "done." Try the cheap substitute FIRST: `claude -p` print-mode uses Claude's own in-process auth and runs from a shell; a direct curl/CLI hit substitutes for "needs-a-session." Most blocks dissolve on a sub-minute check (see `SECOND_GUESS.md`). |

The recurring tell across all four: the disconfirming check is cheap and available, but gets deferred until a Stop-sweep forces it — at which point the claim dissolves. Fire it pre-act, not on sweep N.

**Provenance** (the failures this prevents): filing scenario#629 on an unchecked theory (2026-06-09); recommending "don't ship" off a sub-agent's false won't-compile claim (it was a stale baked SDK, fixed by rebuilding the venv on a clean Python); reporting `[all]`-venv compression as the deployable number when the slim shipping build compressed 0%; and parking a "needs-a-live-session" verification as blocked for 3 turns when `claude -p` ran it (2026-06-10). Spine row: `references/common-mistakes.md` `unverified-claim-acted-on` (faces `completion-word`, `plan-shaped / inherited-prose`, `blocked-without-test`).

## Visual input handling

Rules for processing screenshots, images, and visual assets: `.claude/rules/visual-inputs.md`.
