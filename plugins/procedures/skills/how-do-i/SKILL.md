---
name: how-do-i
description: "The gateway to everything the codex knows. Use when you (or the user) ask 'is there a procedure for X', 'how do we do X', AND — equally — whenever you are ABOUT TO PERFORM a documented operation, whether phrased as a question OR as a direct command ('tag the issue', 'label this PR', 'post to slack', 'cut a release', 'prune/launch/stop/migrate a session', 'run a fleet/orchardist op', 'drive boxd/remote'). An imperative 'do X' is still a trigger: learn the procedure BEFORE executing, not after. Never answer or execute github/slack/release/fleet/boxd operations from memory — those procedures and their paths change and your recall is stale."
user-invocable: true
context: fork
agent: procedure-scout
# PLUGIN ADAPTATION: fork skills ignore their agent's model: — must match
# agents/procedure-scout.md. See README "Fork-skill model pin".
model: sonnet
background: false
argument-hint: "<what you're trying to do>"
---

The caller is about to act and needs to know how it is done here first.

GOAL:

$ARGUMENTS

Search the record stores, read every candidate in full, and return the proposal
in your output shape — what governs, the commands verbatim, the traps, and a
standing label on every source.

Tooling: the query interface is
`bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh"` — survey, recall,
and batch-read all go through it, and `--list-stores` prints the exact scan
surface (the `titw/` vendor store included, plus any extras named in
`QUERY_RECORDS_EXTRA_STORES`, space-separated root-relative paths; settings
`env` maps stack by scope, so projects can add stores). Your Boundaries carry
the rule about what that excludes.

Start warm. Before step 1, read what you already returned this session:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/session-digest-read.sh" --read "${CLAUDE_SESSION_ID}"
```

Empty output means this is the session's first pass — say nothing about it and
proceed cold.

Anything it prints is your own earlier digest. It answered a DIFFERENT goal, so
it tells you where to look first, never a search you can skip. Run your full
query pass regardless — what governs THIS goal is exactly what the earlier one
never needed. Then label each source in your proposal:

- **already established** — the digest above carried it; cite it without
  re-deriving.
- **newly found** — this search surfaced it.

If the goal is ambiguous, say which reading you took rather than picking one
silently.
