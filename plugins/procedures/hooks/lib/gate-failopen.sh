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
        *) why="unrecognized:${why}" ;;
    esac
    printf '{"ts":"%s","gate":"%s","why":"%s","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$gate" "$why" "$sid" \
        >> "$GATE_FAILOPEN_LOG" 2>/dev/null || true
    exit 0
}
