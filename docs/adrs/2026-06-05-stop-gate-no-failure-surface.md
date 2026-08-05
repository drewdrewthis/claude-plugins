---
id: dec.2026-06-05-stop-gate-no-failure-surface
kind: decision
date: 2026-06-05
keywords: [stop-hook, done-gate, terminal-discipline, false-premise, trivial-task]
links: {}
status: accepted
title: When the Stop gate has no failure surface, stop honestly — don't fabricate work
tags: [stop-hook, done-gate, terminal-discipline, false-premise, trivial-task]
supersedes_memory: [false-premise-terminal, done-gate-trivial-task-loop]
---

# Decision

The `done-gate-stop.sh` Stop hook (and the done-bar in `WHAT_DONE_LOOKS_LIKE.md`) is written for **substantive work with a real failure surface** — edge cases, untested paths, codex changes, a mandate to advance. Two situations have **no failure surface**, and the gate has no honest signal to release on:

1. **Trivially-complete task** — e.g. "create file X, rename to Y" — one verified two-step diff. No edge cases, no untested paths.
2. **False-premise request** — e.g. "change one value in the existing `config.yaml`" when no such file exists on any reachable surface.

In both, the correct terminal is to **stop and report honestly**. It is NOT to:
- (a) keep emitting re-affirmations on each Stop re-fire → trips [[parrot-stop-responses]] / [[stop-acknowledgment-as-action]];
- (b) invent tasks to feed `TaskList` so the gate "sees work" → trips [[ask-when-rules-decide]] / fabrication;
- (c) re-run identical read-only searches on each re-fire → [[parrot-stop-responses]].

## How to apply

**Trivially-complete task:** Run `TaskList` once to confirm clean, verify file state read-only (does NOT restart the count), record any genuine recurring friction once, then land the honest **Done** terminal and stop. The honest answer to "name one thing left" is *nothing* — that is a valid Done, not a gap.

**False-premise request:** "Done" = (1) answer the question correctly on its own terms (e.g. read-first holds regardless of which file it is), (2) surface the false premise as the **headline finding**, (3) escalate the single user-held input (the missing path) — but only *after* proving the block survives a real search (multiple roots, depth, recency sweep). That escalation is the narrow legitimate hand-back, not the deferral reflex. Do NOT TaskCreate "make the edit" for a nonexistent file (structurally unadvanceable) or "harden the change" (ceremony for a nonexistent artifact).

The one genuinely additive move on a Stop re-fire with an empty/clean TaskList and no file changes is **capturing the durable lesson** (a memory/decision record like this one) — then stop.

## Why

The done-bar measures fidelity to the *actual* request. When the request is trivial or rests on a false premise, there is nothing to enumerate, so the gate keeps firing past its own stated release condition (3+ clean sweeps + clean `TaskList` + no file changes) because it has no signal. Manufacturing work to satisfy a structural gate is the inverse failure of parroting — both are ways of avoiding the honest terminal.

## Provenance

Merged from two per-machine memory files captured during scenario-test dogfooding sessions (2026-06, origin sessions `5850f9b3…` and `c0fd83bb…`). Promoted to a fleet-shared decision record because the lesson is cross-cutting Stop-gate discipline, not machine-local recall. The native auto-memory store is per-machine (gitignored) and cannot carry this to the fleet.

## See also
- `references/decisions/2026-05-28-stop-is-reinjection-not-wall.md` — Stop is a re-injection mechanism, every fire is a productivity push
- `references/decisions/2026-05-19-stop-hook-and-vocabulary.md` — one universal Stop hook; TaskList not TodoWrite as source of truth
- `references/common-mistakes.md` → `parrot-stop-responses`, `stop-acknowledgment-as-action`, `ask-when-rules-decide`
- `WHAT_DONE_LOOKS_LIKE.md` — the done-bar the gate injects
