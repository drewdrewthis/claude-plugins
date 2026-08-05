---
id: dec.2026-06-09-procedure-atomic-unit-is-document
kind: decision
date: 2026-06-09
keywords: [codex-architecture, procedures, skills-parity, migration, evolve-loop]
links: {}
status: pending
situation_tags: [codex-architecture, procedures, skills-parity, migration, evolve-loop]
resolve_after: 2026-06-23
---
# The atomic unit of a "procedure" is the DOCUMENT, not the INDEX entry

## Goal
**Stated:** Mirror the skills architecture for procedures — per-procedure dir (`<cat>/<name>/PROCEDURE.md` + `EVOLUTION.md` + optional `scripts/`).
**Real:** Achieve parity of the *evolve-after-use loop* — procedures should get improved after they're used, the way skills do via `evolve-skill.md`. The dir layout is the enabling mechanism; the EVOLUTION loop is the prize.

## Values protocol
Reversible local refactor · structural time-horizon (always-loaded resolver + convention set forever) · favor lowest break-risk path that still delivers the evolve loop · no floor/values stakes (local file moves, git-tracked, revertible).

## Chosen path
**One dir per DOCUMENT (flat `.md` file), not per INDEX entry.**
- Each `references/procedures/<cat>/<name>.md` → `<cat>/<name>/PROCEDURE.md` via `git mv`.
- `lifecycle.md` (the ONLY multi-entry file — 7 INDEX anchors: launch/start/spawn/migrate/stop/recover/split) becomes a SINGLE `fleet-session/lifecycle/PROCEDURE.md` retaining all 7 `#anchor` sections. Its 7 INDEX entries point at `lifecycle/PROCEDURE.md#<anchor>`; anchors preserved byte-for-byte so the 25 anchored inbound refs only need the path prefix updated, not the anchor.
- EVOLUTION.md is **per-dir (per-document)**: lifecycle's 7 sections share one EVOLUTION.md. Accepted because those 7 phases were authored as one cohesive doc and evolve together.

## Autonomy verdict
decided-and-acting — reversible refactor, no values call, user invoked /decide to get a resolution not a menu.

## Consequences foreseen
- (immediate) Clean `git mv` preserves history; anchors survive; ~50 inbound refs (incl. 11 in live hooks, a .bats test, scenario-tests/skills.json) get path-prefixed. [load-bearing — these are NOT redirect-covered]
- (structural) "Procedure unit = document" becomes the codex convention. Consistent with how docs are authored (shared-context multi-phase docs stay whole).
- (structural) The evolve loop keys on "which PROCEDURE.md was followed this session" — document-grain, which matches the discovery signal (you follow a doc, not an anchor, in practice).
- (residual, accepted) A multi-procedure doc's EVOLUTION.md mixes evolution notes for all its sections. Irreducible without splitting the doc; acceptable because the sections co-evolve.

## Consequences that materialized
[pending]

## Outcome
[pending]

## Process-soundness
[pending]

## Regrets
[pending]
