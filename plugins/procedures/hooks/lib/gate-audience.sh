#!/usr/bin/env bash
# gate-audience.sh — shared audience predicates for the per-turn invariant gates.
#
# SINGLE RESPONSIBILITY: answer "does this invariant bind THIS session?" and
# nothing else. Storage lives in turn-state.sh; policy in each gate.
#
# AUDIENCES:
#   /how-do-i   — every MAIN agent.
#   /am-i-done  — every MAIN agent.
#
# A SUBAGENT IS NEVER GATED, for any invariant. A delegated specialist runs
# under its own contract and cannot satisfy a per-turn invariant that belongs to
# the session that spawned it — gating it would deadlock the delegation the
# gates exist to encourage.
#
# The subagent discriminator is `.agent_id` in the tool payload, present only on
# a delegated call. It is a payload fact, not an environment guess: the agent
# marker can be absent from /proc/<pid>/environ for some session shapes, so
# environment alone cannot carry this decision.

set -uo pipefail

# ga_is_subagent <payload> — 0 when this call comes from a delegated subagent.
ga_is_subagent() {
    local payload="${1:-}" aid=""
    aid="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null || true)"
    [ -n "$aid" ]
}

# ga_binds_main <payload> — 0 when a main-agent invariant (/how-do-i,
# /am-i-done) binds this call. Every non-subagent session is a main agent.
ga_binds_main() {
    ga_is_subagent "${1:-}" && return 1
    return 0
}
