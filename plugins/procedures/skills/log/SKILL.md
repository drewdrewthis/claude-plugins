---
name: log
description: Record something durable to your own knowledge store — a procedure (repeatable way of doing something for your person), a decision (settled choice), or a solution (reusable fix/pattern). Use when your person corrects how you did something, when a choice gets settled, or when you figure out something you'll need again. Templates ship in this skill's templates/ directory.
user-invocable: true
argument-hint: "<procedure|decision|solution> <details>"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# /log — write it down so /how-do-i can find it

Three record types, three destinations. Copy the matching template from
`${CLAUDE_SKILL_DIR}/templates/` — don't freestyle the shape. The knowledge
root below is `$KNOWLEDGE_REFS` if set, else `~/.claude/references`.

| type | when | where |
|---|---|---|
| **procedure** | a repeatable operation, especially "how my person likes X done" | `<root>/procedures/<kebab-name>/PROCEDURE.md` (template: `PROCEDURE_TEMPLATE.md`; seed its `EVOLUTION.md` from `EVOLUTION_TEMPLATE.md`) |
| **decision** | a settled non-trivial choice you'll need to honor later | append one JSON line to `<root>/decisions.jsonl` (template: `DECISION_TEMPLATE.md`) |
| **solution** | a reusable fix/pattern for a problem that will recur | `<root>/solutions/<YYYY-MM-DD>-<kebab-name>.md` (template: `SOLUTION_TEMPLATE.md`) |
| **principle** | a durable how-to-think rule that shapes many tasks | `<root>/principles/<kebab-name>.md` (template: `PRINCIPLE_TEMPLATE.md`) |
| **failure-mode** | a mistake pattern learned from a correction, so it never recurs | `<root>/failure-modes/<kebab-name>.md` (template: `FAILURE_MODE_TEMPLATE.md`) |

## Frontmatter — every record, no exceptions

Every record .md begins with the six-key frontmatter block: `id`, `kind`,
`date`, `keywords` (non-empty — the discovery surface), `links`, `status`.
The templates carry the shape; a PostToolUse hook lints every record you
write and blocks the turn's flow until you fix a violation. Markdown without
frontmatter is invisible to discovery — it may as well not exist.

## EVOLUTION.md — a procedure's memory

Every procedure directory carries an `EVOLUTION.md` beside its content
(template: `EVOLUTION_TEMPLATE.md`). On every material edit to a procedure, append one
dated line — what changed and the incident/correction that motivated it,
newest first. Never rewrite old lines. This is how the next agent knows an
edit was settled, not accidental.

## Rules

- **Check for an existing record first** (`/how-do-i` on the topic). Amend the
  existing one rather than writing a near-duplicate.
- **Frontmatter keywords are the findability** — choose the words future-you
  would actually search with, including your person's own vocabulary.
- A correction from your person is the highest-value trigger: log it as a
  procedure (the rule going forward), and put the preference itself in
  `/about-my-person` if it's about them rather than about a task.
- These files hold task knowledge, not private content beyond what the
  procedure needs. Not credentials, ever.
