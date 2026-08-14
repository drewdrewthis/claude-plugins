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
# FAIL-OPEN, BUT OBSERVABLY (ADR-001). No jq, an unreadable lib, or an
# unwritable store => exit 0, and append one line to GATE_FAILOPEN_LOG first.
# These are BLIND paths: the hook could not do its job and cannot tell whether
# it should have. Left silent, a permanently missing jq or an unwritable store
# removes warm starts for every session with no signal anywhere.
#
# An unparseable payload, a non-Skill tool, another skill's name, or a result
# with no digest in it are NOT recorded — the hook evaluated correctly and
# declined. Recording those would make the log useless as a rate numerator,
# which is the same BLIND/LEGITIMATE line gate-failopen.sh draws.
#
# PLUGIN ADAPTATION: no upstream counterpart — this hook exists only because
# /how-do-i is a forked skill here (see lib/session-digest.sh). Class:
# "Fork-path session state" in the root README.

set -uo pipefail

# Resolved with ${BASH_SOURCE[0]%/*} rather than `dirname`, and sourced BEFORE
# the jq check, on gate-failopen.sh's own constraint: a missing jq is one of the
# conditions this must record, and that path can run with PATH emptied, so
# anything shelling out to locate the recorder is unreachable exactly when it is
# needed. (turn-state-record.sh uses `dirname` because it sources nothing before
# its jq check.)
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
# The recorder cannot record its own absence — with no gate_failopen to call,
# exit 0 rather than brick the turn.
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || true)"
# gate_failopen never returns; it records and exits 0.
command -v jq >/dev/null 2>&1 || gate_failopen digest-record no-jq

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Skill" ] || exit 0

SKILL="$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .input.skill) // empty' 2>/dev/null || true)"
case "$SKILL" in
    how-do-i|procedures:how-do-i) ;;
    *) exit 0 ;;
esac

# Read the session id BEFORE sourcing the digest lib, so an unreadable lib can
# still be recorded against the session it happened in. It needs only jq, which
# is already known present.
SID_RAW="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

# shellcheck source=lib/session-digest.sh
. "$SCRIPT_DIR/lib/session-digest.sh" 2>/dev/null \
    || gate_failopen digest-record lib-unreadable:session-digest "$SID_RAW"

# NOT a fail-open: sd_key refuses an un-interpolated ${CLAUDE_SESSION_ID} on
# purpose, so that every such caller degrades to a cold start instead of sharing
# one bogus bucket. That is the hook working, not the hook blinded.
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

# sd_write returns nonzero only on its BLIND paths (store not creatable, digest
# not writable) — never for "nothing worth storing", which returns 0.
printf '%s' "$BODY" | sd_write "$KEY" || gate_failopen digest-record store-unwritable "$KEY"

exit 0
