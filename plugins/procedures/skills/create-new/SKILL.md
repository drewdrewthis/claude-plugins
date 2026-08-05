---
name: create-new
description: Create a NEW knowledge artifact — a procedure, a reference doc, or a skill — when novel work succeeded and nothing covers it yet. Use after "none found" from /how-do-i or a "Procedures followed" gap. Patching something that exists is /evolve; recording a fact is /log.
user-invocable: true
argument-hint: "<procedure|reference|skill> <what it should cover>"
---

# /create-new — crystallize novel work

Thin wrapper. Pick the artifact kind, then read and follow the matching
procedure in `${CLAUDE_SKILL_DIR}/references/`:

| kind | procedure | destination |
|---|---|---|
| **procedure** | `create-procedure-PROCEDURE.md` | `$CODEX_ROOT/references/procedures/<name>/PROCEDURE.md` (default `~/.claude/references`) + seed its `EVOLUTION.md` (templates in the log skill) |
| **reference** | `create-reference-PROCEDURE.md` | `$CODEX_ROOT/references/docs/` (or the store the procedure names) |
| **skill** | `create-skill-PROCEDURE.md` | a new skill directory — only when the operation earns an invocation handle (see `docs/adrs/001-procedural-knowledge-system.md`) |

Rules that hold regardless of kind: check `/how-do-i` for an existing
artifact first; six-key frontmatter on every record (the frontmatter hook
enforces it); draft-then-promote — a first success earns a draft, promotion
needs the gate in `docs/adrs/001-procedural-knowledge-system.md` ("Evolution").
