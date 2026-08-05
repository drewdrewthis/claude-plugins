---
id: dec.2026-08-02-skill-is-a-gateway-with-context
kind: decision
date: 2026-08-02
keywords: [skill, gateway, taxonomy, agent-dispatch, doc-shape, lint, D3, how-do-i, am-i-done, executor]
links:
  decisions: [dec.2026-06-18-procedure-is-prose-script-skill-is-executor]
status: active
---
# A skill is a gateway with context — not only a script wrapper

## Goal

**Stated:** Settle what a `SKILL.md` may be a gateway *to*, so the doc-shape lint
and the taxonomy record stop contradicting each other.

**Real:** Unblock the agent-dispatching skills (`how-do-i`, `am-i-done`), which
are a shape neither existing rule anticipated.

## The contradiction

Two owner-stated rules disagreed:

| Source | Says |
|---|---|
| `dec.2026-06-18` (taxonomy) | A skill is a thin wrapper carrying "a single *read and follow `references/procedures/<cat>/<name>/PROCEDURE.md`* instruction" |
| doc-shape lint **D3** (2026-07-31) | "a skill provides context about how to use a script; otherwise it's a procedure" |

A thin pointer-skill names no script, so the taxonomy's own canonical shape
failed D3. That was never resolved — it was absorbed by grandfathering
`skills/respond/` and `skills/challenge/` into `references/.lint-legacy-doc-shape`.
A grandfather list holding the canonical shape is the tell that the rule, not the
files, was wrong.

Surfaced when `how-do-i` and `am-i-done` were rewritten to dispatch agents: a
third target neither rule covered.

## Decision

**Owner-stated:** *"a skill is a gateway with context. It can be used to invoke an
agent, or provide knowledge up front about how to use a script. how-do-i is the
gateway to all knowledge."*

A `SKILL.md` is a **gateway with context**. Three legitimate targets:

| Target | Example |
|---|---|
| A script | knowledge up front about how to run it |
| An agent | dispatch, plus how to read and challenge what comes back |
| A procedure | a pointer at its `PROCEDURE.md` |

What makes it a skill is that it is the **invocation handle** plus the context
needed to use what is behind it — not what kind of thing is behind it. The
"context" half is load-bearing and distinguishes a gateway from a bare alias: a
caller who invokes `how-do-i` needs to know the proposal can be challenged and
that an `asserted` source is not a ruling. That guidance belongs at the gateway,
because it is only true at the moment of invocation.

## Consequences

- **D3 accepts four forms**: a `scripts/` path, a `.sh`/`.py` invocation, a
  `references/procedures/` pointer, or a named agent to dispatch. Renamed
  SKILL-SCRIPT → SKILL-GATEWAY.
- **`skills/respond/SKILL.md` graduated** from `.lint-legacy-doc-shape`
  immediately — it was only ever there because D3 was too narrow. The
  shrink-only ratchet caught this on the same run and forced the deletion.
- `skills/challenge/SKILL.md` still fails D3 and stays grandfathered; it gates
  onto neither script, agent, nor procedure, which is a real defect in that file
  rather than in the rule.
- The taxonomy of `dec.2026-06-18` otherwise stands: procedure = prose script,
  hook = deterministic enforcement, content lives in the procedure. Only the
  skill's permitted *targets* widened.

## Autonomy verdict

`decided-by-owner` — asserted directly in session, resolving a contradiction
between two prior owner-stated rules. Recorded `active`: the change is a
reversible lint edit and the grandfather-list graduation is mechanically
verifiable (`scripts/lint-doc-shape.sh`, rc=0).
