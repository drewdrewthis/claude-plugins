---
name: am-i-done
description: "Get a cold read on finished work before calling it done. Write the am-i-done report (template in this skill's templates/ directory), then invoke this with it — a reviewer reads it and returns findings tagged BLOCKING / FOLLOW-UP / BACKGROUND / LEAVE. Required once on any turn that called tools — research and verification turns included, not just ones that wrote files. Use before the closing TL;DR, not instead of it."
user-invocable: true
context: fork
agent: work-reviewer
# PLUGIN ADAPTATION: fork skills ignore their agent's model: — must match
# agents/work-reviewer.md. See README "Fork-skill model pin".
model: sonnet
background: false
argument-hint: "<the am-i-done report>"
# PLUGIN ADAPTATION: the fork may inherit the parent toolset; this key is a
# best-effort second layer. The reviewer needs only Bash (one pipeline run)
# and Agent (one evolution dispatch); everything else is judgment over pasted
# text.
disallowed-tools: Read, Grep, Glob, Write, Edit, NotebookEdit
---

Review this am-i-done report and return findings.

REPORT:

$ARGUMENTS

A claim without its command and output is "no evidence shown" — not something to
go and check yourself.

Your two allowed actions beyond reading the report (the shape guard enforces
both budgets; see agents/work-reviewer.md for the full contract):

1. ONE corpus verification lookup, only when a finding hinges on what a record
   says:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/how-do-i.sh" --question '<the question the finding hinges on>'
   ```

2. ONE dispatch of the evolution agent with the report + your findings + which
   "Procedures followed" rows route:

   ```
   Agent(subagent_type: "procedures:procedure-evolver",
         prompt: <the full report> + <your findings> + <routed rows>)
   ```

Everything else is judged from the report alone.

Route the report's "Procedures followed" section per your *Read "Procedures
followed" as evolution input* step.

If the report is empty or is not an am-i-done report, say so and return nothing
else.
