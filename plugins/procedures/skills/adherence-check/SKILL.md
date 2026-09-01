---
name: adherence-check
description: "A cold, skeptical read on finished work before calling it done. Write the adherence-check report (template in this skill's templates/ directory), then invoke this with it — a reviewer reads it and returns findings tagged BLOCKING / FOLLOW-UP / BACKGROUND / LEAVE. Self-invoked, not a gate obligation — reach for it whenever you want a second pass: before a PR, after a risky or wide-reaching change, before the closing TL;DR. Use before the TL;DR, not instead of it."
user-invocable: true
context: fork
agent: work-reviewer
# PLUGIN ADAPTATION: fork skills ignore their agent's model: — must match
# agents/work-reviewer.md. See README "Fork-skill model pin".
model: sonnet
# By design, no evolution-dispatch action here — the shape guard permits
# exactly one Bash call (the how-do-i.sh lookup below) and nothing else.
# Record evolution fires from the evolve-sweep Stop hook, not from this fork.
background: false
argument-hint: "<the adherence-check report>"
# PLUGIN ADAPTATION: the fork may inherit the parent toolset; this key is a
# best-effort second layer. The reviewer needs only Bash (one pipeline run);
# everything else is judgment over pasted text.
disallowed-tools: Read, Grep, Glob, Write, Edit, NotebookEdit
---

Review this adherence-check report and return findings.

REPORT:

$ARGUMENTS

A claim without its command and output is "no evidence shown" — not something to
go and check yourself.

Your ONE allowed action beyond reading the report (the shape guard enforces
the budget; see agents/work-reviewer.md for the full contract):

1. ONE corpus verification lookup, only when a finding hinges on what a record
   says:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/how-do-i.sh" --question '<the question the finding hinges on>'
   ```

Everything else is judged from the report alone. Record evolution is NOT part
of this review — it fires from the evolve-sweep hook into
procedures:procedure-evolver.

If the report is empty or is not an adherence-check report, say so and return
nothing else.
