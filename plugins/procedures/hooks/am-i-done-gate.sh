#!/usr/bin/env bash
# am-i-done-gate.sh — Stop hook.
#
# SINGLE RESPONSIBILITY: on a turn that called any tool, require ONE
# Skill(procedures:am-i-done) review before the turn ends. Nothing else.
#
# REPLACES the retired 3-pass streak sweep (done-gate-stop.sh, deleted
# orchard-codex#197). That hook asked the agent to re-grade its own work N
# times; this asks a fresh reviewer once. Three
# self-grades of the same prose is not three checks — the author who missed a
# gap on pass 1 has no new information on pass 3, and the sweep cost three full
# turns to learn that. One independent read is cheaper and catches more.
#
# BOUNDED BY CONSTRUCTION: the gate asks at most ONCE per turn. If the agent
# does not run the skill after being asked, the turn is released anyway. A gate
# that can ask twice can ask forever, and an unclearable gate teaches agents to
# stop verifying in order to escape it.
#
# FAIL-OPEN everywhere: no jq, no session, no transcript, unreadable state, no
# tool use => release. A Stop hook that blocks on its own bug bricks a session.
# Blind fail-opens are RECORDED (see gate_failopen, hooks/lib/gate-failopen.sh)
# — an inert gate and a healthy one are otherwise indistinguishable, which is
# how alerters die unseen.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Resolve our own directory WITHOUT the external `dirname` binary: PATH is
# emptied entirely on the no-jq test path below (gate-failopen.bats "no-jq
# ordering"), and `${x%/*}` is parameter expansion, not a command lookup, so
# it still works. `cd`/`pwd` are bash builtins too — nothing here needs PATH.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0

# PLUGIN ADAPTATION: this gate's own off-switch — userConfig
# `enable_am_i_done_gate`, on by default. See lib/gate-escape.sh. Sourced here,
# CALLED at the block point, so the escape record means "a gate was released"
# rather than "a hook process started". EXCEPTION: on degenerate paths (no jq,
# unreadable lib) the switch is asked FIRST, before audience filtering — a set
# switch is a better explanation of a release than blindness, and without jq the
# audience cannot be known. Those rows are not audience-filtered. An unreadable
# lib leaves the gate ARMED.
# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true

# gate_failopen <gate> <why> [session_id] — hooks/lib/gate-failopen.sh
# (orchard-codex#210 AC-4). Sourced FIRST, before the jq check, so every
# degenerate path below can reach it. If THIS is unreadable we cannot record
# our own absence — release silently (gate-failopen.bats "G5 bootstrap hole").
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

# jq: without it we cannot even read the event name, so every later release
# would be blind.
command -v jq >/dev/null 2>&1 || ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "no-jq"

# Not a Stop event => not ours. A legitimate release, not blindness.
[ "$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "Stop" ] || exit 0

# Ephemeral one-shot (claude --print / SDK): no human to report to.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-cli) exit 0 ;; esac

# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "lib-unreadable:turn-state"
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "lib-unreadable:gate-audience"
# shellcheck source=lib/turn-activity.sh
. "$SCRIPT_DIR/lib/turn-activity.sh" 2>/dev/null || ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "lib-unreadable:turn-activity"

# Not our audience (subagent, or a non-main agent) => legitimate release.
ga_binds_main "$INPUT" || exit 0

SID="$(ts_session_id "$INPUT")"
# No .turn marker => the reset hook never ran => the gate is unwired, not clear.
ts_turn_started "$SID" || ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "reset-hook-never-ran" "$SID"

# Already reviewed this turn => release.
ts_is_marked "$SID" am_i_done && exit 0

# Already asked once this turn => release regardless. Bounded by construction.
ts_is_marked "$SID" am_i_done_asked && exit 0

# No tool use => a conversational turn => release silently.
# Could not tell => release, but on the record.
ta_turn_used_tools "$SID"
case "$?" in
    0) ;;                                   # tools were used — ask for the review
    1) exit 0 ;;                            # clean turn
    *) ge_release_or_failopen "AM_I_DONE_GATE" "am-i-done" "activity-undetermined" "$SID" ;;
esac

# PLUGIN ADAPTATION: plugin-scoped skill name in the message below, plus this
# resolvability check — see README "Plugin-scoped skill names in gate messages".
#
# Same resolvability proxy as how-do-i-gate.sh — see the long note there for
# why a file check is the best available seam and why it is one-sided. Checked
# BEFORE the mark: recording "asked" for a review we never actually asked for
# would suppress the next legitimate ask this turn.
[ -r "$SCRIPT_DIR/../skills/am-i-done/SKILL.md" ] \
    || gate_failopen "am-i-done" "skill-unresolvable" "$SID"

# Everything above said this turn WOULD be blocked. Only now does the switch
# matter, so only now is a release worth recording — and the mark is not set,
# because a released turn was never asked.
if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "AM_I_DONE_GATE"; then exit 0; fi

ts_mark "$SID" am_i_done_asked

jq -nc --arg r "AM-I-DONE: this turn used tools, and the work has not been reviewed. Run Skill(procedures:am-i-done) with a report of what you did and the evidence for it — each claim paired with the command you ran and its actual output. A reviewer will read it once and return follow-ups. Asked once per turn; the next Stop releases either way." '{
  decision: "block",
  reason: $r
}'
exit 0
