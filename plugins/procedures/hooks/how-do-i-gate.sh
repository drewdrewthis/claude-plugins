#!/usr/bin/env bash
# how-do-i-gate.sh — PreToolUse hook (all tools; no matcher).
#
# SINGLE RESPONSIBILITY: enforce ONE invariant — Skill(how-do-i) runs before a
# main agent acts. Split out of respond-gate.sh 2026-08-02: the two invariants
# bind different audiences, so they are two gates.
#
# AUDIENCE: every MAIN agent (owner-set 2026-08-02, resolving orchard-codex#99).
# Subagents are never gated — a delegated specialist runs its own contract, and
# /how-do-i dispatches a subagent, so gating one would deadlock the delegation.
#
# WHY BLOCKING: advisory does not bind. Measured 2026-08-02 — a UserPromptSubmit
# hook emitting "/respond" reaches the model, but the harness labels it
# "UserPromptSubmit hook success: …", so it arrives as log output, not a command;
# the session never invoked the skill. The prior advisory banner produced the
# compliance ritual without the Skill call. Only a gate changes behaviour.
#
# FAIL-OPEN: missing jq, missing turn state, unreadable payload => ALLOW. A
# BLIND fail-open (never a legitimate one) is recorded — see
# hooks/lib/gate-failopen.sh, orchard-codex#210 AC-4.

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
# jq's absence is itself one of the paths this must record, so the recorder
# has to be reachable before that check runs. If gate-failopen.sh itself is
# unreadable we cannot record our own absence — release silently
# (gate-failopen.bats "G5 bootstrap hole").
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || gate_failopen "how-do-i" "no-jq"

# Unlike gate-failopen.sh above, these fail with the recorder already loaded —
# so they are BLIND fail-opens we can and do record, not silent ones.
# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || gate_failopen "how-do-i" "lib-unreadable:turn-state"
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || gate_failopen "how-do-i" "lib-unreadable:gate-audience"
# shellcheck source=lib/gate-allowlist.sh
. "$SCRIPT_DIR/lib/gate-allowlist.sh" 2>/dev/null || gate_failopen "how-do-i" "lib-unreadable:gate-allowlist"

ga_binds_main "$INPUT" || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"
gal_is_compliance_path "$TOOL_NAME" "$INPUT" && exit 0

SID="$(ts_session_id "$INPUT")"
# No .turn marker => the reset hook never ran => the gate is unwired, not
# clear. Record (BLIND), then allow.
ts_turn_started "$SID" || gate_failopen "how-do-i" "reset-hook-never-ran" "$SID"
ts_is_marked "$SID" how_do_i && exit 0

jq -nc --arg r "HOW-DO-I-GATE: this turn has not run Skill(how-do-i). Run it before acting, then retry. Reads under references/procedures/ and read-only discovery commands stay available — look first, then ask, then act (CLAUDE.md invariant; enforced by hooks/how-do-i-gate.sh)." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
