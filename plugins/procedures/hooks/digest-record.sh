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
# machine's transcripts. THAT MEASUREMENT WAS OF THE WRONG THING and the claim
# it produced ("always a string, wrapped in `Skill ... completed (forked
# execution). Result:`") is FALSIFIED. Transcript entries are a RENDERING of a
# tool result; hook stdin carries the raw serialization, and they differ. The
# extractor built on the rendering matched nothing on the real payload, so the
# hook silently wrote no digest at all — the feature was inert in production
# while its unit tests were green, because the tests encoded the same wrong
# shape.
#
# The REAL payload, captured live off this hook's stdin with tee:
#
#   "tool_response": {
#     "success": true, "status": "forked",
#     "commandName": "procedures:how-do-i",
#     "agentId": "a088acab367b38ac7",
#     "result": "<the scout's digest, PLAIN — no wrapper>"
#   }
#
# So .tool_response is an OBJECT and the digest is .result, unwrapped. The
# string+wrapper form is kept below as a fallback because it is what the
# transcript rendering shows and may be what some other dispatch path emits;
# it costs one branch and removing it would be another shape assumption.
#
# LOSING THE WRAPPER LOSES A FILTER. On the string path the wrapper's presence
# was itself the proof that a real fork completed. The object path has no such
# marker, so the rejections it used to give for free are now EXPLICIT: a
# background run, a user refusal, and a "Launching skill" notice must each be
# refused by name, or the next scout replays a refusal as established fact.
#
# hooks/tests/session-digest.bats feeds the captured payload verbatim as a
# fixture, so this shape is pinned by real evidence rather than by inference.
BODY="$(printf '%s' "$INPUT" | jq -r '
    (.tool_response // .response // empty) as $r
    | (
        if ($r | type) == "object" then
            # The live shape. Require the fork to have actually succeeded.
            $r | select((.status? == "forked") and (.success? == true)) | (.result? // empty)
        elif ($r | type) == "string" then
            # Legacy/rendered shape: the wrapper is required, as before.
            $r
            | select(test("^Skill \"[^\"]*\" completed \\(forked execution\\)\\.\\s*\\n\\s*Result:"))
            | sub("^Skill \"[^\"]*\" completed \\(forked execution\\)\\.\\s*\\n\\s*Result:\\s*\\n?"; "")
        else empty end
      )
    | select(type == "string")
    # Explicit rejections (see above). Apostrophes are avoided in these patterns
    # so the jq program stays inside one single-quoted shell string.
    | select(test("^\\s*Scout is running in the background") | not)
    | select(test("want to proceed with this tool use") | not)
    | select(test("^\\s*Launching skill:") | not)
' 2>/dev/null || true)"

if [ -z "$BODY" ]; then
    # A digest-free result is only LEGITIMATE if we recognise why it is empty.
    # Anything else means this hook was handed its own skill's completion and
    # could not find the digest in it — which is exactly the blind condition
    # that let the object-shape bug run silently in production. Record it, so
    # the next serialization change is loud on its first occurrence instead of
    # after a dogfood run.
    BENIGN="$(printf '%s' "$INPUT" | jq -r '
        (.tool_response // .response // empty) as $r
        | ( if ($r | type) == "object" then ($r.result? // "")
            elif ($r | type) == "string" then $r
            else "" end ) as $t
        | if ($t | test("want to proceed with this tool use")) then "refused"
          elif ($t | test("^\\s*Scout is running in the background")) then "background"
          elif ($t | test("^\\s*Launching skill:")) then "launching"
          elif (($r | type) == "object" and ($r.success? == false)) then "failed"
          else "" end
    ' 2>/dev/null || true)"
    [ -n "$BENIGN" ] && exit 0
    gate_failopen digest-record payload-shape-unrecognized "$SID_RAW"
fi

# sd_write returns nonzero only on its BLIND paths (store not creatable, digest
# not writable) — never for "nothing worth storing", which returns 0.
printf '%s' "$BODY" | sd_write "$KEY" || gate_failopen digest-record store-unwritable "$KEY"

exit 0
