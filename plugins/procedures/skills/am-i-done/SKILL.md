---
name: am-i-done
description: "Get a cold read on finished work before calling it done. Write the handoff report (${CLAUDE_SKILL_DIR}/templates/HANDOFF_REPORT_TEMPLATE.md), then invoke this with it — a reviewer reads it and returns findings tagged BLOCKING / FOLLOW-UP / BACKGROUND / LEAVE. Required once on any turn that called tools — research and verification turns included, not just ones that wrote files. Use before the closing TL;DR, not instead of it."
user-invocable: true
context: fork
agent: work-reviewer
background: false
argument-hint: "<the handoff report>"
---

Review this handoff report and return findings.

REPORT:

$ARGUMENTS

A claim without its command and output is "no evidence shown" — not something to
go and check yourself.

If the report is empty or is not a handoff report, say so and return nothing
else.
