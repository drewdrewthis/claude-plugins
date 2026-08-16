#!/usr/bin/env bats
# Fail-open INSTRUMENTATION tests for orchard-codex#210 AC-4.
#
# gates.bats proves gate POLICY; gate-libs.bats proves the shared libs. This
# file proves the RECORDING contract: gate_failopen() extracted out of
# am-i-done-gate.sh into hooks/lib/gate-failopen.sh, sibling
# to hooks/lib/turn-state.sh, and wired into all three gates so every BLIND
# fail-open — never a legitimate release — is recorded with its own gate's
# name. The blind-vs-legitimate line is drawn by the FAIL-OPEN comment block at
# the head of hooks/am-i-done-gate.sh and by ADR-016's "Every gate fails open"
# section; this file must not blur it.
#
# BLIND (must be recorded): reset-hook-never-ran, no-jq, lib-unreadable:*,
# activity-undetermined. NOT script-dir-unresolvable, and NOT
# lib-unreadable:gate-failopen — both fail before the recorder exists to call,
# so both release silently (hooks/lib/gate-failopen.sh header; case 4/G5 below).
# LEGITIMATE (must record NOTHING): out-of-audience (ga_binds_main
# false), the compliance-path allowlist, a clean no-tool turn, sdk-cli, a
# non-Stop event.
#
# ⚠ GATE_FAILOPEN_LOG DANGER — READ BEFORE EDITING THIS FILE. gate_failopen()
# defaults to the REAL $HOME/.claude/gate-failopen.jsonl (the GATE_FAILOPEN_LOG
# assignment in hooks/lib/gate-failopen.sh) when the var is unset. That default is exactly what leaked 11+ rows of
# hooks/tests/gates.bats's own runs into production telemetry — root-caused
# 2026-08-03, see plans/REENTRY-issue210-gate-failopen.md and the regression
# test in gates.bats ("root cause #210: this suite does not leak..."). EVERY
# test below drives gates through the `drive()` helper, which pins BOTH
# GATE_FAILOPEN_LOG and HOME to scratch paths on every single call — never
# call a gate script directly without it.
#
# Run: bats hooks/tests/gate-failopen.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  REPO="$BATS_TEST_DIRNAME/../.."

  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gf-ts.XXXXXX")"
  LOG_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gf-log.XXXXXX")"
  export GATE_FAILOPEN_LOG="$LOG_DIR/gate-failopen.jsonl"

  # turn-activity.sh's transcript glob is hardcoded to "$HOME"/.claude/projects
  # and gate_failopen's own default log is $HOME-relative too — the exact
  # defect above. FAKE_HOME means no invocation in this file can touch the
  # real ~/.claude tree even if a single GATE_FAILOPEN_LOG export were ever
  # missed on a future edit.
  FAKE_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gf-home.XXXXXX")"
  mkdir -p "$FAKE_HOME/.claude"

  SID="bats-gf-$$-$BATS_TEST_NUMBER"
  PAYLOAD_EDIT="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}"
  PROJ="$FAKE_HOME/.claude/projects/-bats-gf-$$-$BATS_TEST_NUMBER"
  mkdir -p "$PROJ"
  JSONL="$PROJ/$SID.jsonl"
  : > "$JSONL"
  STOP="{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}"
}

teardown() {
  # ${VAR:?} exits the shell, which in a teardown would skip the rm -rf below
  # AND leave a chmod-000 lib unrestored — bricking every gate on the box. It is
  # safe here ONLY because unreadable_lib() sets both vars together or neither,
  # so this can never fire. That invariant is what makes the assertion legal;
  # do not weaken it to a :- default, which would silently restore a guess.
  [ -n "${CHMODDED_LIB:-}" ] && chmod "${CHMODDED_MODE:?unreadable_lib must set both or neither}" "$CHMODDED_LIB" 2>/dev/null
  rm -rf "$TURN_STATE_DIR" "$LOG_DIR" "$FAKE_HOME" 2>/dev/null || true
}

start_turn() { printf '{"session_id":"%s"}' "$SID" | env HOME="$FAKE_HOME" bash "$HOOKS/turn-state-reset.sh"; }

ran_skill() {
  printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"%s"}}' "$SID" "$1" \
    | env HOME="$FAKE_HOME" bash "$HOOKS/turn-state-record.sh"
}

user_prompt() { printf '{"type":"user","message":{"content":"do the thing"}}\n' >> "$JSONL"; }
assistant_tool() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s"}]}}\n' "$1" >> "$JSONL"
}

# drive <gate-script-basename> <CLAUDE_CODE_AGENT value> <json payload>
# Pins GATE_FAILOPEN_LOG and HOME on every call. Never invoke a gate script
# any other way in this file (see the header warning).
drive() {
  env HOME="$FAKE_HOME" CLAUDE_CODE_AGENT="$2" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$3' | bash '$HOOKS/$1'"
}

# unreadable_lib <basename> — make hooks/lib/<basename> unsourceable for this
# test only. Captures the real mode rather than assuming one: restoring a
# guessed mode would leave a permission change in the git diff, and the guess
# was wrong once already. teardown() puts it back.
# Sets CHMODDED_LIB and CHMODDED_MODE together or neither — that ordering is
# the whole point. Setting the path before the mode is captured leaves teardown
# holding a lib to restore and no mode to restore it to, and on the stat-failure
# path the chmod 000 has ALREADY run, so the lib stays unreadable.
# `stat -c` is GNU-only; this repo writes the BSD fallback everywhere else.
unreadable_lib() {
  local lib="$HOOKS/lib/$1" mode
  [ -f "$lib" ] || { echo "no such lib: $lib"; return 1; }
  mode="$(stat -c '%a' "$lib" 2>/dev/null || stat -f '%Lp' "$lib" 2>/dev/null)"
  [ -n "$mode" ] || { echo "cannot stat $lib"; return 1; }
  CHMODDED_MODE="$mode"; CHMODDED_LIB="$lib"
  chmod 000 "$lib"
}

# The SessionStart wiring gap (orchard-codex#214) was asserted here as a
# skipped wiring check. Wiring assertions are config lints, not behaviour
# tests, and belong in CI rather than a bats suite — #214 tracks the defect.

# ---------- case 1: each gate records under its OWN name (AC-4's core) ----------
# am-i-done-gate's own reset-hook-never-ran record is already pinned at
# gates.bats's "am-i-done: records a fail-open when the reset hook never ran"
# and "am-i-done: fails OPEN when the reset hook never ran" — not duplicated
# here. Cited by test NAME, never by line: this PR's own setup() hardening
# shifted every line below it and silently re-pointed the numeric anchors.

@test "case 1: how-do-i-gate records reset-hook-never-ran under gate:\"how-do-i\"" {
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e 'select(.gate == "how-do-i" and .why == "reset-hook-never-ran")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
}

@test "case 1: after exercising both gates, the shared log's gate names are exactly the two" {
  run drive "am-i-done-gate.sh" technician "$STOP"
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  run bash -c "jq -r '.gate' '$GATE_FAILOPEN_LOG' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'am-i-done\nhow-do-i')" ]
}

# ---------- case 2: record shape carries what a rate needs ----------

@test "record shape: am-i-done-gate's fail-open row carries this turn's session_id" {
  run drive "am-i-done-gate.sh" technician "$STOP"
  run jq -r 'select(.gate == "am-i-done" and .why == "reset-hook-never-ran") | .session_id' "$GATE_FAILOPEN_LOG"
  [ "$output" = "$SID" ]
}

@test "record shape: how-do-i-gate's fail-open row carries this turn's session_id" {
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  run jq -r 'select(.gate == "how-do-i" and .why == "reset-hook-never-ran") | .session_id' "$GATE_FAILOPEN_LOG"
  [ "$output" = "$SID" ]
}

@test "record shape: a turn stuck in reset-hook-never-ran writes ONE ROW PER TOOL CALL for how-do-i-gate, not one per turn" {
  # how-do-i-gate.sh is PreToolUse with NO matcher (see its file header) —
  # every tool call re-evaluates the gate. A naive "rows / eligible turns"
  # rate (AC-4's own follow-on measurement, not built here) would silently
  # overcount it relative to the once-per-Stop am-i-done-gate.
  #
  # We do NOT pin a turn-id field to fix this. The one marker that would carry
  # turn identity is $TURN_STATE_DIR/$sid.turn itself, stamped once per turn by
  # ts_reset — and reset-hook-never-ran is BY DEFINITION the case where that
  # marker does not exist. A turn-id derived from it is unavailable in exactly
  # the failure mode most needing dedup. The nonce that would resolve it already
  # EXISTS and is exactly the right shape — the harness mints `prompt.id` per
  # prompt, wholly independent of whether turn-state-reset.sh ran. It is simply
  # not reachable from hook stdin, which carries only session_id /
  # transcript_path / hook_event_name / cwd / permission_mode. Stated this way
  # on purpose: the earlier wording called it unresolvable, which stops a future
  # reader looking for the thing that is already there. See #233. What we
  # CAN and do pin: the multiplication is real, so a future rate calculation
  # is not surprised by it.
  #
  # All three payloads must be ACTS. The allowlist short-circuits ahead of the
  # turn-state lookup — deliberately, so a compliance call never depends on
  # state — so an allowlisted LOOK exits before this recorder is reached and
  # contributes no row. Until 2026-08-09 `Read /tmp/a` and `pwd` were denied
  # and did contribute; now they are looks, and using them here would measure
  # the allowlist rather than the per-call multiplication this pins.
  local P1="{\"session_id\":\"$SID\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/a\"}}"
  local P2="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/b\"}}"
  local P3="{\"session_id\":\"$SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /tmp/c\"}}"
  run drive "how-do-i-gate.sh" technician "$P1"
  run drive "how-do-i-gate.sh" technician "$P2"
  run drive "how-do-i-gate.sh" technician "$P3"
  run bash -c "grep -c 'reset-hook-never-ran' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "3" ]
}

# ---------- case 3: negative controls — legitimate releases write NOTHING ----------
# Each drives the REAL script and asserts the log stays empty (`[ ! -s LOG ]`,
# true whether the file was never created or created-but-empty).

@test "negative control: am-i-done-gate does not record a purely conversational turn" {
  start_turn
  user_prompt
  run drive "am-i-done-gate.sh" technician "$STOP"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

@test "negative control: am-i-done-gate does not record a delegated subagent" {
  start_turn
  user_prompt
  assistant_tool Edit
  local P="{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\",\"agent_id\":\"sub1\"}"
  run drive "am-i-done-gate.sh" technician "$P"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

@test "negative control: am-i-done-gate does not record the sdk-cli entrypoint" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env HOME="$FAKE_HOME" CLAUDE_CODE_AGENT=technician GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    CLAUDE_CODE_ENTRYPOINT=sdk-cli bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

@test "negative control: am-i-done-gate does not record a non-Stop event" {
  start_turn
  user_prompt
  assistant_tool Edit
  local NOTSTOP="{\"session_id\":\"$SID\",\"hook_event_name\":\"SubagentStop\"}"
  run drive "am-i-done-gate.sh" technician "$NOTSTOP"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

@test "negative control: how-do-i-gate does not record a delegated subagent" {
  local P="{\"session_id\":\"$SID\",\"agent_id\":\"sub1\",\"tool_name\":\"Edit\"}"
  run drive "how-do-i-gate.sh" technician "$P"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

@test "negative control: how-do-i-gate does not record on the compliance path" {
  # No start_turn: if the allowlist did not short-circuit first, this would
  # otherwise be a genuine reset-hook-never-ran. Proves allowlist precedence.
  local P="{\"session_id\":\"$SID\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"how-do-i\"}}"
  run drive "how-do-i-gate.sh" technician "$P"
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

# ---------- case 4 / G5: the recorder cannot record its own absence ----------
# A gate that bricks a session because ITS OWN lib is missing is the
# unrecoverable case. We pin the SAFE behaviour (exit 0, silent); we do not
# (cannot) pin a record, because gate_failopen is defined inside the very lib
# that failed to load — see the file header for the blind-vs-legitimate line
# this preserves.

@test "G5 bootstrap hole: am-i-done-gate fails safely when hooks/lib/gate-failopen.sh is itself unreadable" {
  unreadable_lib "gate-failopen.sh" || { echo "AC-4 not yet implemented: hooks/lib/gate-failopen.sh does not exist"; false; }
  run drive "am-i-done-gate.sh" technician "$STOP"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G5 bootstrap hole: how-do-i-gate fails safely when hooks/lib/gate-failopen.sh is itself unreadable" {
  unreadable_lib "gate-failopen.sh" || { echo "AC-4 not yet implemented: hooks/lib/gate-failopen.sh does not exist"; false; }
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- case 4b: an unreadable SIBLING lib IS recorded (G5's complement) ----------
# G5 above pins the ONE lib whose failure cannot be recorded — the recorder
# itself. Every OTHER lib a gate sources fails with gate_failopen already
# loaded, so it is a recordable BLIND fail-open: the gate cannot evaluate, and
# releases without knowing whether it should have blocked. Unrecorded, these
# are invisible in the fail-open rate AC-4 reports, which undercounts it for
# any gate that releases silently here.
#
# Each test leaves the turn otherwise COMPLIANT (start_turn + that gate's own
# skill), so the ONLY thing left to record is the lib failure — a row here
# cannot be a stray reset-hook-never-ran. The `sort -u` assertion is the
# "records under its OWN name" half: a shared or hardcoded gate label fails it.
# ORDER MATTERS: start_turn/ran_skill drive turn-state-record.sh, which sources
# lib/turn-state.sh itself, so they must run BEFORE the chmod.

@test "case 4b: how-do-i-gate records lib-unreadable:turn-state instead of releasing silently" {
  start_turn
  ran_skill how-do-i
  unreadable_lib turn-state.sh
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e 'select(.gate == "how-do-i" and .why == "lib-unreadable:turn-state")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.gate' '$GATE_FAILOPEN_LOG' | sort -u"
  [ "$output" = "how-do-i" ]
}

@test "case 4b: how-do-i-gate records lib-unreadable:gate-audience instead of releasing silently" {
  start_turn
  ran_skill how-do-i
  unreadable_lib gate-audience.sh
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e 'select(.gate == "how-do-i" and .why == "lib-unreadable:gate-audience")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.gate' '$GATE_FAILOPEN_LOG' | sort -u"
  [ "$output" = "how-do-i" ]
}

@test "case 4b: how-do-i-gate records lib-unreadable:gate-allowlist instead of releasing silently" {
  start_turn
  ran_skill how-do-i
  unreadable_lib gate-allowlist.sh
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e 'select(.gate == "how-do-i" and .why == "lib-unreadable:gate-allowlist")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.gate' '$GATE_FAILOPEN_LOG' | sort -u"
  [ "$output" = "how-do-i" ]
}

# ---------- case 5: no-jq must stay recordable (ordering regression guard) ----------
# These pin an ORDERING, which is why they read as trivial and are not.
# Pre-AC-4 both PreToolUse gates ran `command -v jq || exit 0` before SCRIPT_DIR
# resolved and before any lib was sourced, so no shared recorder could be
# reached on that path no matter where it lived. All three gates now source
# lib/gate-failopen.sh FIRST; these tests fail the moment anything reorders that.
# Two properties are load-bearing together: gate_failopen's body uses no jq (a
# missing jq is one of the things it must report), and SCRIPT_DIR resolves via
# ${BASH_SOURCE[0]%/*} and shell builtins — the test below empties PATH
# entirely, so an external `dirname` would itself be unreachable on exactly the
# path that needs it.

@test "no-jq ordering: how-do-i-gate records no-jq instead of a silent, unrecordable exit" {
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    /bin/bash -c "echo '$PAYLOAD_EDIT' | /bin/bash '$HOOKS/how-do-i-gate.sh'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e 'select(.gate == "how-do-i" and .why == "no-jq")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
}

# ---------- case 6 / G6: install propagation ----------

@test "G6 install: a provisioned tree carries hooks/lib/gate-failopen.sh and every gate can source it" {
  # settings.json wires *commands*; nothing looks at the lib/ files those
  # commands source. A new lib can ship in git and miss a box that provisioned before
  # the next sync. This simulates a freshly provisioned hooks/ tree (a plain
  # copy, as a checkout or rsync would produce) and sources the LIB FROM ITS
  # COPIED LOCATION, not the git checkout, so a hardcoded path back into $REPO
  # would also be caught.
  PROV="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gf-prov.XXXXXX")"
  mkdir -p "$PROV/hooks"
  cp -r "$HOOKS/lib" "$PROV/hooks/lib"
  cp "$HOOKS/am-i-done-gate.sh" "$HOOKS/how-do-i-gate.sh" "$PROV/hooks/"

  [ -r "$PROV/hooks/lib/gate-failopen.sh" ] || {
    echo "MISSING from provisioned tree: hooks/lib/gate-failopen.sh (AC-4 not yet implemented)"
    rm -rf "$PROV"
    false
  }

  for g in am-i-done-gate.sh how-do-i-gate.sh; do
    grep -q 'lib/gate-failopen\.sh' "$PROV/hooks/$g" || {
      echo "$g does not source lib/gate-failopen.sh"
      rm -rf "$PROV"
      false
    }
  done

  run bash -c "SCRIPT_DIR='$PROV/hooks'; source '$PROV/hooks/lib/gate-failopen.sh'; declare -F gate_failopen"
  [ "$status" -eq 0 ]

  rm -rf "$PROV"
}

# ---------- case 7: catch-rate non-regression ----------
# am-i-done's block decision is already pinned (gates.bats's "gates a
# research-only turn" and "blocks once on a turn that produced an artifact",
# :199, :207, :220, :226-227) — not duplicated here.

@test "catch-rate non-regression: how-do-i-gate's denial still sets permissionDecision:deny" {
  # GREEN AT HEAD, deliberately — how-do-i-gate.sh's closing `jq -nc` block
  # already emits this field
  # today; gates.bats's "denies ... without how-do-i" cases only pin the reason text (HOW-DO-I-GATE
  # substring), never the structural field the harness actually reads to
  # block the call. This is a regression guard for the AC-4 refactor, not new
  # RED coverage: per the dispatch brief, "a change that trades away gate
  # catch-rate is not a fix" — if this ever goes red, that is what happened.
  start_turn
  run drive "how-do-i-gate.sh" technician "$PAYLOAD_EDIT"
  [[ "$output" == *'"permissionDecision": "deny"'* ]] || [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

# ---------- root-cause-adjacent: what "reset-hook-never-ran" actually covers ----------
# The #210 investigation (2026-08-03) showed the recorded reason can outrun
# its literal name: a marker that EXISTED and then vanished mid-turn is
# indistinguishable, to ts_turn_started, from a reset hook that plain never
# ran — both are just "no .turn file right now". These two pin that the gate
# still fails open SAFELY either way, and that a fail-open is scoped to the
# SESSION ID IN THE PAYLOAD, never to "any turn marker that happens to exist".

@test "root cause #210 follow-on: am-i-done-gate fails open when .turn is deleted mid-turn, not just never created" {
  # GREEN AT HEAD: ts_turn_started only checks file existence, so this is
  # already indistinguishable from "never created" today. Pinned as
  # documentation that the why-string is a hypothesis about MISSING state, not
  # a proven mechanism — exactly the distinction this issue's own
  # investigation had to relearn.
  start_turn
  user_prompt
  assistant_tool Edit
  rm -f "$TURN_STATE_DIR/$SID.turn"
  run drive "am-i-done-gate.sh" technician "$STOP"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run grep -q "reset-hook-never-ran" "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
}

@test "root cause #210 follow-on: a Stop for session B is not satisfied by session A's turn marker" {
  # RED at HEAD: not because of a cross-session bleed (there is none — SID is
  # already correctly threaded through ts_turn_started) but because .session_id
  # is not yet in the record shape (case 2), so the filter below matches
  # nothing today.
  local SID_A="${SID}-a"
  local SID_B="${SID}-b"
  printf '{"session_id":"%s"}' "$SID_A" | env HOME="$FAKE_HOME" bash "$HOOKS/turn-state-reset.sh"
  local STOP_B="{\"session_id\":\"$SID_B\",\"hook_event_name\":\"Stop\"}"
  run drive "am-i-done-gate.sh" technician "$STOP_B"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg sid "$SID_B" 'select(.session_id == $sid) | .why' "$GATE_FAILOPEN_LOG"
  [[ "$output" == *"reset-hook-never-ran"* ]]
}

# ---------- record integrity: the recorder defends its own JSON ----------
# Found by the #220 review fan-out. The record is built by printf, not jq, so
# an unescaped field is one forgetful call site away from a forged record.
# Every call site sanitizes TODAY (ts_session_id runs tr -c 'a-zA-Z0-9_-'), so
# these are defence-in-depth, not a live exploit — they exist so the guarantee
# survives the tenth call site.
#
# ⚠ "the line still parses" is NOT the predicate. The pre-fix behaviour emitted
# VALID JSON carrying an attacker-named extra key; jq -e . passed it happily.
# Assert on the KEY SET.

@test "record integrity: a forged session_id cannot inject a key into the record" {
  run env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'how-do-i' 'no-jq' 'evil\",\"injected\":\"yes'"
  [ "$status" -eq 0 ]
  run bash -c "jq -r 'keys|join(\",\")' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "gate,session_id,ts,why" ]
}

@test "record integrity: a forged why cannot inject a key, including on the lib-unreadable arm" {
  # The lib-unreadable:<basename> suffix is the only why that is structurally a
  # variable, and the first version of the guard sanitized why ONLY on the
  # fallback arm — so this exact payload forged a key while the other two
  # fields were safe. Pinning the arm that was missed, not just the one that
  # was covered.
  run env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'how-do-i' 'lib-unreadable:x\",\"injected\":\"yes' 'sess1'"
  [ "$status" -eq 0 ]
  run bash -c "jq -r 'keys|join(\",\")' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "gate,session_id,ts,why" ]
}

@test "record integrity: a forged gate cannot inject a key" {
  run env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'evil\",\"injected\":\"yes' 'no-jq' 'sess1'"
  [ "$status" -eq 0 ]
  run bash -c "jq -r 'keys|join(\",\")' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "gate,session_id,ts,why" ]
}

@test "record integrity: a newline in any field cannot split one record into two lines" {
  run env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'how-do-i' 'no-jq' \"$(printf 'a\nb')\""
  [ "$status" -eq 0 ]
  run bash -c "wc -l < '$GATE_FAILOPEN_LOG'"
  [ "$output" -eq 1 ]
}

@test "record integrity: an unrecognized why is quarantined, never silently dropped" {
  run env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'how-do-i' 'brand-new-condition' 'sess1'"
  [ "$status" -eq 0 ]
  # Recorded (a dropped record is worse than an unclassified one)...
  [ -s "$GATE_FAILOPEN_LOG" ]
  # ...but prefixed, so it cannot enter a rate a consumer computes unnoticed.
  run bash -c "jq -r '.why' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "unrecognized:brand-new-condition" ]
}

@test "record integrity: every real why value survives the closed set unchanged" {
  for w in no-jq reset-hook-never-ran activity-undetermined lib-unreadable:turn-state; do
    : > "$GATE_FAILOPEN_LOG"
    env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'how-do-i' '$w' 'sess1'"
    run bash -c "jq -r '.why' '$GATE_FAILOPEN_LOG'"
    [ "$output" = "$w" ]
  done
}
