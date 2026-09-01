#!/usr/bin/env bash
# nudge.sh — UserPromptSubmit hook.
#
# SINGLE RESPONSIBILITY: print ONE short reminder that /what-do-i-know and
# /adherence-check exist. Discovery, not enforcement — how-do-i-gate.sh and
# am-i-done-gate.sh used to force these; both are soft (off) by default now,
# and this is their softer replacement.
#
# DELIBERATELY NOT SILENT, unlike turn-state-reset.sh (see that hook's own
# "OUTPUT CONTRACT — SILENT" header). UserPromptSubmit stdout is model-facing;
# how-do-i-gate.sh's header notes an imperative banner on this channel does not
# reliably bind an agent to act. This nudge does not ask for an invocation —
# it states availability — so that finding does not apply here.
#
# Off-switch: userConfig `enable_nudge`, ON by default — see lib/gate-escape.sh.
#
# FAIL-OPEN TOWARD SILENCE: no jq, unreadable lib, subagent audience, switched
# off => print nothing, exit 0. A broken reminder is a skipped reminder, never
# a crash.

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
exit 0
