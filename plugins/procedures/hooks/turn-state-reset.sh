#!/usr/bin/env bash
# turn-state-reset.sh — UserPromptSubmit hook.
#
# SINGLE RESPONSIBILITY: start a new turn. Clears every per-turn invariant flag
# and stamps the turn marker. It never belonged to one gate; it owns the
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

exit 0
