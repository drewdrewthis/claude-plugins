---
name: create-new
description: Create a NEW knowledge artifact — a procedure, a reference doc, or a skill — when novel work succeeded and nothing covers it yet. Use after "none found" from /how-do-i or a "Procedures followed" gap. Patching something that already exists is out of scope here — for a PROCEDURE, patching is /evolve-procedure; a skill, agent, or other record is edited directly and its EVOLUTION.md line logged; recording a fact is /log.
user-invocable: true
argument-hint: "<procedure|reference|skill> <what it should cover>"
---

# /create-new — crystallize novel work

Thin wrapper. Pick the artifact kind, then read and follow the matching
procedure in `${CLAUDE_SKILL_DIR}/references/`:

| kind | procedure | destination |
|---|---|---|
| **procedure** | `create-procedure.procedure.md` | `$CODEX_ROOT/references/procedures/<name>/PROCEDURE.md` (default `~/.claude/references`) + seed its `EVOLUTION.md` (templates in the log skill) |
| **reference** | `create-reference.procedure.md` | `$CODEX_ROOT/references/docs/` (or the store the procedure names) |
| **skill** | `create-skill.procedure.md` | a new skill directory — only when the operation earns an invocation handle (see `docs/adrs/001-procedural-knowledge-system.md`) |
| **rule** | write by hand from the matching template in the log skill | `$CODEX_ROOT/references/{invariants,principles,policies,standards}/` — pick by the test below |

Choosing among the four rule kinds: an **invariant** forbids absolutely and has no
carve-outs — the moment you write "except when", it is a **principle**, which guides
judgment where the rules do not reach. A **policy** grants or withholds authority and is
in force from merge until a line is struck. A **standard** states the measurable bar a
finished artifact must clear, never the steps to clear it. These are not a severity
scale: promoting a rule you still intend to break trains every reader to treat the whole
kind as advice. Run `scripts/grc-coverage.sh` before adding one — it reports which
existing rules are machine-enforced and which are only written.

Rules that hold regardless of kind: check `/how-do-i` for an existing
artifact first; six-key frontmatter on every record (the frontmatter hook
enforces it); draft-then-promote — a first success earns a draft, promotion
needs the gate in `docs/adrs/001-procedural-knowledge-system.md` ("Evolution").
