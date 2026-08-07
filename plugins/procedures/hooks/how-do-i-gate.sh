#!/usr/bin/env bash
# how-do-i-gate.sh — PreToolUse hook (all tools; no matcher).
#
# SINGLE RESPONSIBILITY: enforce ONE invariant — Skill(procedures:how-do-i) runs before a
# main agent acts.
#
# AUDIENCE: every MAIN agent (owner-set 2026-08-02, resolving orchard-codex#99).
# Subagents are never gated — a delegated specialist runs its own contract, and
# /how-do-i dispatches a subagent, so gating one would deadlock the delegation.
#
# WHY BLOCKING: advisory does not bind. Measured — a UserPromptSubmit hook
# emitting a skill invocation reaches the model, but the harness labels it
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

# PLUGIN ADAPTATION: this gate's own off-switch — userConfig
# `enable_how_do_i_gate`, on by default. See lib/gate-escape.sh. Top level with
# its own condition; an unreadable lib leaves the gate ARMED.
# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true
if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "HOW_DO_I_GATE"; then exit 0; fi

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

# PLUGIN ADAPTATION: plugin-scoped skill name in the message below, plus this
# resolvability check — see README "Plugin-scoped skill names in gate messages".
# Upstream the gate lives inside the codex and names the bare skill; shipped in
# a plugin the invocable name is namespaced and the install can arrive
# hooks-first.
#
# About to force an invocation — so the name below has to be one the session can
# actually resolve. Denying while naming a skill that cannot be invoked is a
# HARD WEDGE: deny, retry, deny, with no exit (2026-08-07). The skills ship as a
# sibling of these hooks, so their absence here means a partial install.
#
# JUDGEMENT — this is a PROXY, not a detection. A hook is handed no capability
# manifest: nothing in the payload or the environment enumerates the session's
# registered skills, so "can the model invoke this right now" is not answerable
# from in here. The file check is deliberately ONE-SIDED — present does not
# prove the session registered the skill, but absent proves it cannot be
# invoked. It therefore fires only when we are certain, and introduces no new
# way to wedge. What it misses: skills on disk but disabled in session config.
# Costs one builtin test, no fork.
[ -r "$SCRIPT_DIR/../skills/how-do-i/SKILL.md" ] \
    || gate_failopen "how-do-i" "skill-unresolvable" "$SID"

# The reason string is the ONLY channel this gate has to the blocked agent —
# it is read at the moment of denial, by an agent that may have run how-do-i
# minutes ago in an earlier turn and reads the block as redundant. So it states
# the per-turn scope AND why, or the agent files a bug against the design
# (observed: a main agent proposed exactly that, on the premise that a
# same-session run should carry over). Per-turn re-gating is deliberate and
# load-bearing — see lib/turn-state.sh and turn-state-reset.sh.
jq -nc --arg r "HOW-DO-I-GATE: this turn has not run Skill(procedures:how-do-i). Run it before acting, then retry. Gating is PER TURN by design — one user prompt is one turn, and a lookup from an earlier turn says nothing about what this turn is about to do, so a run earlier in the session does not carry over. The pass is bounded — a typical goal finishes in 3-4 Bash calls in a forked session, not a research project. File reads and read-only shell inspection stay available — look first, then ask, then act (CLAUDE.md invariant; enforced by hooks/how-do-i-gate.sh)." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
