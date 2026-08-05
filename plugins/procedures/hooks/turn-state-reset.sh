#!/usr/bin/env bash
# turn-state-reset.sh — UserPromptSubmit hook.
#
# SINGLE RESPONSIBILITY: start a new turn. Clears every per-turn invariant flag,
# stamps the turn marker, and records what triggered the turn. Renamed from
# respond-gate-reset.sh 2026-08-02 — it never belonged to one gate; it owns the
# turn boundary for all of them.
#
# A "turn" is one user prompt. Flags must not survive it: an invariant satisfied
# last turn says nothing about this one.
#
# THE .turn MARKER IS LOAD-BEARING. It is how a gate distinguishes "new turn,
# nothing satisfied yet" (block) from "this hook never ran" (fail open). Without
# it an unwired reset would look identical to an unsatisfied invariant, and
# every gate would deny every tool call forever.
#
# OUTPUT CONTRACT — SILENT. UserPromptSubmit stdout is MODEL-FACING: anything
# printed here is injected into context every single turn. Advisory injection is
# what this system is removing, not adding. State mutation only, always exit 0.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || exit 0

SID="$(ts_session_id "$INPUT")"
ts_reset "$SID"

# TURN TRIGGER. /respond binds only a DIRECT message from the owner (owner
# directive 2026-08-05); a cron wakeup, a task-notification, or another agent's
# channel message is not one. This hook is the only one that sees the prompt —
# a PreToolUse payload does not carry it — so the trigger must be classified
# here or not at all. Pre-marking the flag the gate already reads keeps the
# policy in one place (respond-gate.sh) and needs no second marker.
#
# FAIL-OPEN: an unreadable lib, an absent prompt, or an unclassifiable one all
# leave the flag unset — i.e. exactly today's behaviour, the gate binds. The
# `declare -F` probe is what keeps that direction true on a box whose checkout
# has this hook but an older lib: an unbound function name would return 127,
# and 127 read as "not direct" would silently disable the gate.
# shellcheck source=lib/gate-audience.sh
if . "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null \
   && declare -F ga_prompt_is_direct_owner >/dev/null 2>&1; then
    # `.input` is the field name this repo's other UserPromptSubmit hook
    # (classify-prompt.sh) reads; try both rather than depend on one harness.
    PROMPT="$(printf '%s' "$INPUT" | jq -r '(.prompt // .input) // empty' 2>/dev/null || true)"
    if ! ga_prompt_is_direct_owner "$PROMPT"; then
        ts_mark "$SID" respond
    fi
fi

exit 0
