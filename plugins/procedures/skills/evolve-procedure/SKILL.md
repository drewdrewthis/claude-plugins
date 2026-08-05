---
name: evolve-procedure
description: Patch an EXISTING procedure record from a correction, incident, or friction — a deviation, a missing step, or a stale/broken ref hit while following a PROCEDURE.md. Use after a procedure was followed and something about it didn't hold up. Scope is procedures only — a skill, agent, or other record is edited directly (see its own EVOLUTION.md convention); a NEW procedure is /create-new; recording a bare fact is /log.
user-invocable: true
argument-hint: "<procedure> <what changed / what friction>"
---

# /evolve-procedure — patch the procedure, don't just remember

Thin wrapper. Read and follow `${CLAUDE_SKILL_DIR}/references/evolve.procedure.md`.

Scope: procedures only. Skills, agents, and other records are edited
directly — this skill does not route to them. A NEW procedure (nothing
existing covers the work) is `/create-new`.

Every material patch this produces appends a dated line to that procedure
directory's `EVOLUTION.md`, newest first — that log is mandatory, not
optional, on any patch that changes behavior.
