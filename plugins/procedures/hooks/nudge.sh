#!/usr/bin/env bash
# nudge.sh — UserPromptSubmit hook.
#
# SINGLE RESPONSIBILITY: discovery, not enforcement. Print ONE short reminder
# that /what-do-i-know and /adherence-check exist, then (PLUGIN ADAPTATION,
# no upstream counterpart) up to RECORD_HINTS_MAX records whose frontmatter
# shares words with the prompt, from scripts/record-hints.sh. how-do-i-gate.sh
# and am-i-done-gate.sh used to force the two skills; both are soft (off) by
# default now, and this is their softer replacement.
#
# DELIBERATELY NOT SILENT, unlike turn-state-reset.sh (see that hook's own
# "OUTPUT CONTRACT — SILENT" header). UserPromptSubmit stdout is model-facing;
# how-do-i-gate.sh's header notes an imperative banner on this channel does not
# reliably bind an agent to act. This nudge does not ask for an invocation —
# it states availability — so that finding does not apply here.
#
# Off-switch: userConfig `enable_nudge`, ON by default — see lib/gate-escape.sh.
# It switches the reminder and the record hints together.
#
# FAIL-OPEN TOWARD SILENCE: no jq, unreadable lib, subagent audience, switched
# off => print nothing, exit 0. A broken reminder is a skipped reminder, never
# a crash. The record hints run after the reminder line is out, capped at
# RECORD_HINTS_TIMEOUT seconds (default 1) where `timeout`/`gtimeout` exists;
# a failed, slow or empty lookup adds nothing and leaves the reminder as is.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || exit 0
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || exit 0

ga_binds_main "$INPUT" || exit 0
ge_enabled "NUDGE" || exit 0

echo "Available: /what-do-i-know (knowledge retrieval), /adherence-check (finished-work review)."

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -n "$PROMPT" ] || exit 0
HINTS_SCRIPT="$SCRIPT_DIR/../scripts/record-hints.sh"
[ -r "$HINTS_SCRIPT" ] || exit 0
LIMIT=()
if command -v timeout >/dev/null 2>&1; then
    LIMIT=(timeout "${RECORD_HINTS_TIMEOUT:-1}")
elif command -v gtimeout >/dev/null 2>&1; then
    LIMIT=(gtimeout "${RECORD_HINTS_TIMEOUT:-1}")
fi
HINTS="$(printf '%s' "$PROMPT" | ${LIMIT[@]+"${LIMIT[@]}"} bash "$HINTS_SCRIPT" 2>/dev/null)" || HINTS=""
[ -n "$HINTS" ] && printf '%s\n' "$HINTS"
exit 0
