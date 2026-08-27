#!/usr/bin/env bash
# gate-failopen.sh — shared fail-open recorder for the per-turn invariant gates.
#
# RESPONSIBILITY: perform a blind fail-open, observably — append the record,
# then release.
#
# THIS FUNCTION NEVER RETURNS. It exits 0. That is why every test calling it
# needs a fresh subshell per invocation.
#
# BLIND (record): reset-hook-never-ran, no-jq, lib-unreadable:*,
# activity-undetermined — the gate could not evaluate.
# store-unwritable — the caller could not persist what it was asked to persist.
# payload-shape-unrecognized — the caller was handed its own event and could not
# find the field it needed in it. A serialization change must be loud on its
# first occurrence, not discovered by dogfooding weeks later.
# malformed-payload — stdin would not parse at all, so no filter downstream can
# be trusted to mean what it says.
# skill-unresolvable — the gate was about to DENY while naming a skill the
# install cannot resolve (hooks shipped, skills absent). Denying there is a hard
# wedge: deny, retry, deny, with no exit. Releasing is the only safe branch, and
# it must be loud — a silently ungated session looks exactly like a compliant one.
# transcript-unreadable — a caller that reads the session transcript could not
# get at it (missing, unreadable, or no python3 to parse it). Distinct from a
# transcript that READS but holds nothing to record, which is a legitimate
# decline: this one says the input surface is gone, that one says the surface
# was fine and empty.
# judgment-unavailable — a caller whose record has a mechanical half and a
# model-judged half wrote the mechanical half but could not obtain the
# judgment. The row exists and is short a field; the record says why, so a
# model outage is not read later as a turn where nothing happened.
# detach-failed — a caller that hands its work to a detached child could not
# launch one (no temp file for the payload, an unwritable $TMPDIR). Kept
# distinct from store-unwritable: the store is not touched on that path, and
# naming it points whoever reads the log at the wrong directory.
# non-object-payload — stdin parsed, but the top-level value is not an envelope
# (a bare string, an array, a number). Kept distinct from malformed-payload:
# that one says the transport is broken, this one says something is plumbing
# the wrong event in. Both silently skip if unchecked, since indexing a
# non-object yields empty and reads as "a different tool fired".
#
# NOT ONLY GATES. digest-record.sh ("Fork-path session state" in the root
# README) and worklog-record.sh ("Turn worklog") record here too, each under its
# own <gate> name. They are writers, not gates, and their failures are not gate
# misses — group by <gate> before computing any fail-open rate, which the
# per-caller naming rule below already requires.
# LEGITIMATE (never record): out-of-audience, the compliance-path allowlist, a
# clean no-tool turn, sdk-cli, a non-Stop event — the gate DID evaluate and
# correctly released. Blurring this line makes the log useless as a fail-open
# rate numerator. Canonical statement: ADR-016's "Every gate fails open".
#
# NOT script-dir-unresolvable: reaching this file requires SCRIPT_DIR to have
# resolved, so a failure there leaves no recorder to call.
#
# USES NO JQ. A missing jq is itself one of the paths this must record, so the
# recorder cannot depend on the thing it is reporting absent.
#
# CALLERS MUST SOURCE THIS BEFORE THE JQ CHECK, via a SCRIPT_DIR resolved
# without the external `dirname` binary (see the callers) — jq's absence is
# checked on the no-jq test path with PATH emptied entirely, so anything that
# shells out to find this file is itself unreachable on exactly the path that
# needs it (gate-failopen.bats "no-jq ordering").
#
# THE RECORDER CANNOT RECORD ITS OWN ABSENCE. If this file is unreadable, the
# caller has no gate_failopen to call — it must exit 0 silently rather than
# brick the session (gate-failopen.bats "G5 bootstrap hole").

set -uo pipefail

GATE_FAILOPEN_LOG="${GATE_FAILOPEN_LOG:-$HOME/.claude/gate-failopen.jsonl}"

# gate_failopen <gate> <why> [session_id] — append one record and exit 0.
# <gate> is the caller's own name (am-i-done | how-do-i): each gate
# records under itself, never a shared/hardcoded label. <session_id> is
# omitted (empty) exactly when the caller could not determine it either (e.g.
# the no-jq path, where session_id parsing needs the very jq that is absent).
# Best-effort throughout: logging must never block a Stop or PreToolUse
# decision.
gate_failopen() {
    local gate="${1:-unknown}" why="${2:-unknown}" sid="${3:-}"
    # The record is built by printf, not jq, so every field must be made safe
    # for a JSON string literal HERE. Callers do sanitize today — ts_session_id
    # runs tr -c 'a-zA-Z0-9_-' — but a field reaching an unescaped %s is one
    # forgetful call site away from a forged record, and the failure is silent:
    # a sid of `x","injected":"y` yields a line that still PARSES, carrying an
    # attacker-named extra key. "Valid JSON" is not the predicate; the key set
    # is. Defence belongs where the string is built.
    # ONE class, applied to all three fields BEFORE any branching. The first
    # version of this guard sanitized `why` only on the fallback arm, so
    # `lib-unreadable:<basename>` — the one why whose suffix is structurally a
    # variable — passed straight through and still forged a key. Sanitize
    # first, classify second; never the reverse.
    # This also strips every C0 control character, including the newline that
    # would otherwise split one record across two JSONL lines.
    gate="${gate//[^A-Za-z0-9_.:-]/_}"
    sid="${sid//[^A-Za-z0-9_.:-]/_}"
    why="${why//[^A-Za-z0-9_.:-]/_}"
    # Closed reason set. An unrecognized why is RECORDED, never dropped — but
    # quarantined under a prefix so it cannot silently enter a rate a consumer
    # computes, and so adding a condition without updating this list is visible
    # in the log itself rather than only in a header comment.
    case "$why" in
        no-jq|reset-hook-never-ran|activity-undetermined|lib-unreadable:*) ;;
        store-unwritable|payload-shape-unrecognized|malformed-payload) ;;
        non-object-payload|skill-unresolvable) ;;
        transcript-unreadable|judgment-unavailable|detach-failed) ;;
        *) why="unrecognized:${why}" ;;
    esac
    printf '{"ts":"%s","gate":"%s","why":"%s","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$gate" "$why" "$sid" \
        >> "$GATE_FAILOPEN_LOG" 2>/dev/null || true
    exit 0
}

# PLUGIN ADAPTATION: no upstream counterpart. ge_release_or_failopen exists only
# to serve the plugin-only gate-escape.sh, which upstream does not have, and this
# shim covers the state where that lib is unreadable.
# ge_release_or_failopen fallback. gate-escape.sh defines the real one and is
# sourced FIRST by both gates, so this guard never clobbers it — it only covers
# the state where that lib was unreadable. Without it an undefined function
# returns 127 and execution FALLS THROUGH into the gate's deny/block, which is
# the one outcome a degraded path must never produce.
declare -F ge_release_or_failopen >/dev/null 2>&1 || ge_release_or_failopen() { shift; gate_failopen "$@"; }
