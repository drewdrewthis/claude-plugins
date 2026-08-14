#!/usr/bin/env bash
# digest-record.sh — PostToolUse hook (matcher: Skill).
#
# SINGLE RESPONSIBILITY: persist the digest a /how-do-i fork just returned, so
# the next /how-do-i in this session starts warm. It records the PAYLOAD; the
# per-turn INVARIANT is turn-state-record.sh's job and stays there — one hook,
# one fact.
#
# This never affects whether the gate fires. The gate reads turn-state markers,
# which this hook does not touch; a digest changes only what the next fork
# starts with. (Issue #24's explicit anti-goal: do not memoize "the gate ran".)
#
# NAMESPACE-QUALIFIED NAMES TOO, on the same rule turn-state-record.sh uses:
# the bare name and THIS plugin's "procedures:" prefix, never a bare wildcard —
# an unrelated `evil:how-do-i` must not be able to plant a digest that the next
# fork will read as established fact.
#
# FAIL-OPEN: no jq, unparseable payload, no extractable body, unwritable store
# => exit 0 silently. A missing digest costs a cold start, which is exactly
# today's behaviour; a crash here would cost the turn.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Skill" ] || exit 0

SKILL="$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .input.skill) // empty' 2>/dev/null || true)"
case "$SKILL" in
    how-do-i|procedures:how-do-i) ;;
    *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=lib/session-digest.sh
. "$SCRIPT_DIR/lib/session-digest.sh" 2>/dev/null || exit 0

SID_RAW="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
KEY="$(sd_key "$SID_RAW")" || exit 0

# The fork's return value, measured over 260 how-do-i Skill results in this
# machine's transcripts: ALWAYS a string, and 247 of them wrapped as
#
#   Skill "procedures:how-do-i" completed (forked execution).
#
#   Result:
#   <the scout's digest>
#
# The wrapper is REQUIRED, not merely stripped, because it is what separates a
# digest from the other 13: 7 were "The user doesn't want to proceed with this
# tool use." (the caller rejected the skill) and 6 were "Launching skill:
# how-do-i". Storing either would replay a refusal to the next scout as an
# established finding. No wrapper => no digest => cold start.
#
# A `background: true` fork returns the wrapper around "Scout is running in the
# background", which WOULD be stored — skills/how-do-i/SKILL.md pins
# `background: false`, so that shape cannot arrive here.
BODY="$(printf '%s' "$INPUT" | jq -r '
    (.tool_response // .response // empty)
    | if type == "string" then . else empty end
    | select(test("^Skill \"[^\"]*\" completed \\(forked execution\\)\\.\\s*\\n\\s*Result:"))
    | sub("^Skill \"[^\"]*\" completed \\(forked execution\\)\\.\\s*\\n\\s*Result:\\s*\\n?"; "")
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | sd_write "$KEY"

exit 0
