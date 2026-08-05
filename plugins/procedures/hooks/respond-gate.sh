#!/usr/bin/env bash
# respond-gate.sh — PreToolUse hook (all tools; no matcher).
#
# SINGLE RESPONSIBILITY: enforce ONE invariant — Skill(respond) runs before the
# assistant acts. It enforced /how-do-i too until 2026-08-02; that invariant now
# lives in how-do-i-gate.sh because it binds a different audience. One file
# enforcing two invariants for two audiences is why the scoping was hard to
# reason about (orchard-codex#99).
#
# AUDIENCE: the assistant only (owner-set 2026-08-02, resolving #99). Storage in
# lib/turn-state.sh, audience in lib/gate-audience.sh, allowlist in
# lib/gate-allowlist.sh — this file is policy only.
#
# FAIL-OPEN: missing jq, missing turn state (reset hook unwired or a resumed
# session whose first UserPromptSubmit has not fired), or any unreadable payload
# ALLOWS. A gate that blocks on its own bug bricks a session. A BLIND fail-open
# (never a legitimate one) is recorded — see hooks/lib/gate-failopen.sh,
# orchard-codex#210 AC-4.
#
# OUTPUT: DENY => permissionDecision "deny" + reason, exit 0. ALLOW => silent.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Resolve our own directory WITHOUT the external `dirname` binary: PATH is
# emptied entirely on the no-jq test path below (gate-failopen.bats "no-jq
# ordering"), and `${x%/*}` is parameter expansion, not a command lookup, so
# it still works. `cd`/`pwd` are bash builtins too — nothing here needs PATH.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0
# gate_failopen <gate> <why> [session_id]. Sourced BEFORE the jq check below —
# see how-do-i-gate.sh for why the ordering is load-bearing. If
# gate-failopen.sh itself is unreadable we cannot record our own absence —
# release silently (gate-failopen.bats "G5 bootstrap hole").
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || gate_failopen "respond" "no-jq"

# Unlike gate-failopen.sh above, these fail with the recorder already loaded —
# so they are BLIND fail-opens we can and do record, not silent ones.
# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || gate_failopen "respond" "lib-unreadable:turn-state"
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || gate_failopen "respond" "lib-unreadable:gate-audience"
# shellcheck source=lib/gate-allowlist.sh
. "$SCRIPT_DIR/lib/gate-allowlist.sh" 2>/dev/null || gate_failopen "respond" "lib-unreadable:gate-allowlist"

# Not this invariant's audience => allow.
ga_binds_respond "$INPUT" || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"
gal_is_compliance_path "$TOOL_NAME" "$INPUT" && exit 0

SID="$(ts_session_id "$INPUT")"
# Reset hook has not run => cannot distinguish unsatisfied from unwired =>
# record (BLIND) then allow.
ts_turn_started "$SID" || gate_failopen "respond" "reset-hook-never-ran" "$SID"
ts_is_marked "$SID" respond && exit 0

jq -nc --arg r "RESPOND-GATE: this turn has not run Skill(respond). Run it before any other tool call, then retry. Until then only Skill, Agent, and reads under references/procedures/ are permitted (CLAUDE.md invariant; enforced by hooks/respond-gate.sh)." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
