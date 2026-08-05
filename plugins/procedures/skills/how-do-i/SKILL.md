---
name: how-do-i
description: "The gateway to everything the codex knows. Use when you (or the user) ask 'is there a procedure for X', 'how do we do X', AND — equally — whenever you are ABOUT TO PERFORM a documented operation, whether phrased as a question OR as a direct command ('tag the issue', 'label this PR', 'post to slack', 'cut a release', 'prune/launch/stop/migrate a session', 'run a fleet/orchardist op', 'drive boxd/remote'). An imperative 'do X' is still a trigger: learn the procedure BEFORE executing, not after. Never answer or execute github/slack/release/fleet/boxd operations from memory — those procedures and their paths change and your recall is stale."
user-invocable: true
context: fork
agent: procedure-scout
background: false
argument-hint: "<what you're trying to do>"
---

The caller is about to act and needs to know how it is done here first.

GOAL:

$ARGUMENTS

Search the record stores, read every candidate in full, and return the proposal
in your output shape — what governs, the commands verbatim, the traps, and a
standing label on every source.

If the goal is ambiguous, say which reading you took rather than picking one
silently.
