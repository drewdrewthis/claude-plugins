---
id: proc.codex-meta.evolve-procedure
kind: procedure
date: 2026-06-25
keywords: [evolve, evolve-procedure, improve, patch, procedure, correction, friction, codify]
links: []
status: active
---

# /evolve-procedure

Patches an existing `PROCEDURE.md` from real usage evidence — a deviation,
a missing step, or a stale/broken ref hit while following it — and appends
the dated line to that procedure directory's `EVOLUTION.md`. Scope boundaries
are the SKILL.md's; the table below is only the routing check.

**$ARGUMENTS:** `<procedure> <what changed / what friction>` — the target
procedure (path or name) and the correction. If the procedure name is
omitted, scan the current conversation for the `PROCEDURE.md` whose steps
this turn actually followed. If nothing actionable is found, say so and
stop — not every following of a procedure produces an evolution.

## Before dispatching: confirm this is a procedure patch

| Situation | Action |
|---|---|
| A `PROCEDURE.md` was followed this session and something about it (a step, a ref, an instruction) didn't hold up | **This skill** — proceed to `steps/evolve-procedure.md` |
| No procedure exists yet for work that just succeeded | **`/update-records procedure`** — not this skill |
| The friction was in a skill, agent, hook, CLAUDE.md row, or other record, not a procedure | **Edit that artifact directly** and log its own `EVOLUTION.md`/changelog if it keeps one — not this skill |
| The only actionable output is a fact worth recording, with no procedure text to change | **`/update-records mistake`** (or the matching record kind) — not this skill |

A single turn can touch more than one of these; this skill only owns the
procedure-patch lane. Dispatch the others separately.

## Dispatch

Read and follow `references/steps/evolve-procedure.md` against the target
procedure identified above. That step file owns:

- gathering evidence (mistakes log + conversation) for deviations, missing
  steps, and broken/stale refs
- diagnosing root cause vs one-off
- applying the minimal patch
- appending the dated line to the SAME directory's `EVOLUTION.md`
- reporting what changed and what was left alone

Records referenced by path in this doc and its steps file live under
`$CODEX_ROOT/references` (default `~/.claude/references`); adjust the root
if this install overrides it.

## Anti-patterns

- **Evolving without a real correction** — if evidence-gathering can't name
  a concrete deviation, missing step, or broken ref, stop. Speculative
  "improvements" belong in a rewrite, not an evolution.
- **Reaching past scope** — patching a skill or agent file from here instead
  of naming it as a separate direct edit.
- **Skipping the EVOLUTION.md log** — the dated line is the audit trail;
  always append it after a patch that changes behavior.
