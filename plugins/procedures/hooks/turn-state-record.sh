#!/usr/bin/env bash
# turn-state-record.sh — PostToolUse hook (matcher: Skill).
#
# SINGLE RESPONSIBILITY: record that a per-turn invariant was satisfied — it
# records for every gate, not one.
#
# PostToolUse(Skill) fires when the Skill tool RETURNS, which is before the
# skill's own body has finished acting. That ordering is deliberate: calling
# Skill(how-do-i) marks the flag before how-do-i's own greps and subagent
# dispatch run, so the gate does not deny the skill mid-execution.
#
# EXACT NAMES ONLY. An unrelated `evil:how-do-i` must not satisfy the invariant,
# so the case arms match the real skill identifiers and nothing wildcarded.
#
# FAIL-OPEN: no jq, unparseable payload, unwritable state => exit 0 silently.
# A failed record means a gate asks again, which is recoverable; a crash here
# is not.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Skill" ] || exit 0

SKILL="$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .input.skill) // empty' 2>/dev/null || true)"
case "$SKILL" in
    how-do-i)   KEY="how_do_i" ;;
    am-i-done)  KEY="am_i_done" ;;
    *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || exit 0

ts_mark "$(ts_session_id "$INPUT")" "$KEY"

exit 0
