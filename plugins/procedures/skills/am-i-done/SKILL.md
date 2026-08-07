---
name: am-i-done
description: "Get a cold read on finished work before calling it done. Write the am-i-done report (template in this skill's templates/ directory), then invoke this with it — a reviewer reads it and returns findings tagged BLOCKING / FOLLOW-UP / BACKGROUND / LEAVE. Required once on any turn that called tools — research and verification turns included, not just ones that wrote files. Use before the closing TL;DR, not instead of it."
user-invocable: true
context: fork
agent: work-reviewer
# PLUGIN ADAPTATION: a context:fork skill inherits the PARENT SESSION's model,
# not the model agents/work-reviewer.md declares. Without this pin the reviewer
# runs at whatever tier the caller happens to be on. Upstream has no equivalent
# because the gate does not run as a forked skill there.
model: sonnet
background: false
argument-hint: "<the am-i-done report>"
---

Review this am-i-done report and return findings.

REPORT:

$ARGUMENTS

A claim without its command and output is "no evidence shown" — not something to
go and check yourself.

Route the report's "Procedures followed" section per your *Read "Procedures
followed" as evolution input* step.

If the report is empty or is not an am-i-done report, say so and return nothing
else.
