---
name: evolve
description: Improve an existing knowledge artifact from a correction, friction, or surprise — patch a procedure, a skill, or another record so the lesson lands where the next agent will read it. Use when something you followed was wrong, stale, or costly to use. Creating a NEW artifact is /create-new; recording a fact is /log.
user-invocable: true
argument-hint: "[the correction/friction — or empty to scan the conversation for the latest one]"
---

# /evolve — patch the artifact, don't just remember

Thin wrapper. Read and follow `${CLAUDE_SKILL_DIR}/references/PROCEDURE.md`,
which dispatches to:

- `references/steps/evolve-procedure.md` — patching a PROCEDURE.md (and
  appending the dated line to its EVOLUTION.md — mandatory).
- `references/evolve-skill-PROCEDURE.md` — the precision routine for SKILL.md
  patches, which chains to the `references/steps/evolve-skill.md` checklist.
- `/log mistake` — when the lesson is a correction to record, not an edit.
- `/create-new` — when no artifact exists to evolve.

Adjust the paths it names to this install: records live under
`$CODEX_ROOT/references` (default `~/.claude/references`); templates ship in
the log skill's `templates/`.
