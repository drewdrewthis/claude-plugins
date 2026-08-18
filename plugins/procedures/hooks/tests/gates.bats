#!/usr/bin/env bats
# Policy tests for the three per-turn gates.
#
# The libraries are covered by gate-libs.bats; these prove POLICY only —
# who is denied, when, and that every degenerate path releases.
#
# Run: bats hooks/tests/gates.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gates.XXXXXX")"
  # orchard-codex#210 root cause: gate_failopen() defaults this to the REAL
  # $HOME/.claude/gate-failopen.jsonl (the GATE_FAILOPEN_LOG assignment in
  # hooks/lib/gate-failopen.sh). Leaving it unset
  # here is what leaked this suite's own runs into production telemetry (see
  # "root cause #210" test below). HOME is ALSO redirected: PROJ two lines
  # down and gate_failopen's own default are both $HOME-relative, so a fake
  # HOME closes both holes with one export, and covers any future $HOME-relative
  # default too.
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gates-home.XXXXXX")"
  mkdir -p "$HOME/.claude"
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/gate-failopen.jsonl"
  SID="bats-g-$$-$BATS_TEST_NUMBER"
  PAYLOAD_EDIT="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}"
  # am-i-done-gate reads the transcript, which must live where it looks.
  PROJ="$HOME/.claude/projects/-bats-g-$$-$BATS_TEST_NUMBER"
  mkdir -p "$PROJ"
  JSONL="$PROJ/$SID.jsonl"
  : > "$JSONL"
  STOP="{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}"
}

teardown() {
  rm -rf "$TURN_STATE_DIR" "$HOME" 2>/dev/null || true
}

start_turn() { printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"; }

# start_turn_with <prompt> — a turn carrying the text that triggered it. jq
# builds the payload so channel tags' own quotes survive intact.
start_turn_with() {
  jq -nc --arg s "$SID" --arg p "$1" '{session_id:$s, prompt:$p}' \
    | bash "$HOOKS/turn-state-reset.sh"
}

ran_skill() {
  printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"%s"}}' "$SID" "$1" \
    | bash "$HOOKS/turn-state-record.sh"
}

user_prompt() { printf '{"type":"user","message":{"content":"do the thing"}}\n' >> "$JSONL"; }
assistant_tool() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s"}]}}\n' "$1" >> "$JSONL"
}

# ---------- turn-state-record ----------

@test "record: an evil:how-do-i look-alike does NOT satisfy the invariant" {
  start_turn
  printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"evil:how-do-i"}}' "$SID" \
    | bash "$HOOKS/turn-state-record.sh"
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"deny"* ]]
}

@test "record: the legacy {tool,input} payload shape still marks the flag" {
  start_turn
  printf '{"session_id":"%s","tool":"Skill","input":{"skill":"how-do-i"}}' "$SID" \
    | bash "$HOOKS/turn-state-record.sh"
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

@test "record: an unrelated skill marks nothing" {
  start_turn
  ran_skill "some-other-skill"
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"deny"* ]]
}

@test "record: namespaced procedures:how-do-i stamps the how_do_i marker" {
  start_turn
  ran_skill "procedures:how-do-i"
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

@test "record: namespaced procedures:am-i-done stamps its marker" {
  start_turn
  user_prompt
  assistant_tool Edit
  ran_skill "procedures:am-i-done"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "record: an unrelated namespaced skill foo:bar marks nothing" {
  start_turn
  ran_skill "foo:bar"
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"deny"* ]]
}

@test "record: a non-Skill tool is ignored and exits clean" {
  start_turn
  run bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/turn-state-record.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "record: a jq-less machine fails OPEN and stays silent" {
  start_turn
  # Absolute interpreter path: with PATH emptied, `bash` itself is unresolvable,
  # which would fail the rig rather than exercise the hook's jq-less path.
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" /bin/bash -c "echo '{}' | /bin/bash '$HOOKS/turn-state-record.sh'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- turn-state-reset ----------

@test "reset: the hook stays silent (UserPromptSubmit stdout is model-facing)" {
  run start_turn
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- how-do-i-gate ----------

@test "how-do-i-gate: denies a named main agent until the skill runs" {
  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  # Pins the per-turn-scope explanation itself, not just the HOW-DO-I-GATE
  # header — a trim of the payload's body text would otherwise stay green.
  [[ "$output" == *"PER TURN"* ]]
  # The two clauses that do the persuading. The whole point of this message is
  # that an agent who ran the skill last turn reads the block as bureaucracy and
  # argues with the invariant instead of clearing it. Pin the reason, not just
  # the instruction, or a later trim quietly restores the bare version.
  [[ "$output" == *"does not carry over"* ]]
  [[ "$output" == *"bounded"* ]]
}

@test "how-do-i-gate: a skill run in an EARLIER turn does not release this one" {
  # The invariant the deny message asserts, tested as behaviour rather than as
  # prose. Without this, the message could claim per-turn scope while the gate
  # actually honoured a stale flag, and both the message test above and the
  # same-turn release test below would still pass.
  start_turn
  ran_skill how-do-i
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]

  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
}

@test "how-do-i-gate: allows once Skill(how-do-i) has run" {
  start_turn
  ran_skill how-do-i
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

@test "how-do-i-gate: allows a compliance Agent dispatch while outstanding (no deadlock)" {
  start_turn
  P="{\"session_id\":\"$SID\",\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"procedures how-do-i lookup\"}}"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

@test "how-do-i-gate: denies a work-delegation Agent dispatch while outstanding" {
  start_turn
  P="{\"session_id\":\"$SID\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"description\":\"refactor auth\",\"prompt\":\"edit src/auth.ts\"}}"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
}

@test "how-do-i-gate: allows reading a procedure while outstanding" {
  start_turn
  P="{\"session_id\":\"$SID\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/h/references/procedures/a/PROCEDURE.md\"}}"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

@test "how-do-i-gate: never gates a delegated subagent" {
  start_turn
  P="{\"session_id\":\"$SID\",\"agent_id\":\"sub1\",\"tool_name\":\"Edit\"}"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]
}

# ---------- am-i-done-gate ----------

@test "am-i-done: releases a purely conversational turn (no tools at all)" {
  start_turn
  user_prompt
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: gates a research-only turn (Bash/Read, nothing written)" {
  # Owner decision 2026-08-02: gate after ANY tool call. Research turns are
  # exactly where a wrong conclusion ships unchallenged.
  start_turn
  user_prompt
  assistant_tool Bash
  assistant_tool Read
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
  [[ "$output" == *"block"* ]]
}

@test "am-i-done: blocks once on a turn that produced an artifact" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
  [[ "$output" == *"block"* ]]
}

@test "am-i-done: a delegated Agent call counts as an artifact" {
  start_turn
  user_prompt
  assistant_tool Agent
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
}

@test "am-i-done: asks at most ONCE per turn, then releases" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
  # Second Stop with no new work: must release, not loop.
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: re-arms on the NEXT turn" {
  # The owner's invariant is once per TURN. Asking once per session is the bug
  # this pins: turn 2 must block again after its own artifact.
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]

  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
  [[ "$output" == *"block"* ]]
}

@test "am-i-done: releases once the skill has run" {
  start_turn
  user_prompt
  assistant_tool Edit
  ran_skill am-i-done
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: a new user prompt resets the activity window" {
  start_turn
  user_prompt
  assistant_tool Edit
  user_prompt          # new turn began; the Edit belongs to the previous one
  start_turn           # reset hook fires on the new prompt
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: records a fail-open when the reset hook never ran" {
  # No start_turn => no .turn marker => the gate is unwired, not clear. AC-2:
  # "an inert reviewer must be detectable".
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/failopen.jsonl"
  run env CLAUDE_CODE_AGENT=technician GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
}

@test "am-i-done: records a fail-open on a jq-less machine" {
  start_turn
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/failopen.jsonl"
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    /bin/bash -c "echo '$STOP' | /bin/bash '$HOOKS/am-i-done-gate.sh'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'no-jq' "$GATE_FAILOPEN_LOG"
}

@test "am-i-done: records a fail-open when activity cannot be determined" {
  # A gate that releases blindly must be distinguishable from one that releases
  # because the turn was clean. Silent fail-open is how alerters die unseen.
  start_turn
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/failopen.jsonl"
  rm -f "$JSONL"        # transcript gone => cannot tell
  run env CLAUDE_CODE_AGENT=technician GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'activity-undetermined' "$GATE_FAILOPEN_LOG"
}

@test "am-i-done: never gates a delegated subagent" {
  start_turn
  user_prompt
  assistant_tool Edit
  P="{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\",\"agent_id\":\"sub1\"}"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$P' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: fails OPEN when the reset hook never ran" {
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

@test "am-i-done: releases for the sdk-cli entrypoint" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician CLAUDE_CODE_ENTRYPOINT=sdk-cli \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ -z "$output" ]
}

# ---------- test-harness hygiene (orchard-codex#210 root cause, 2026-08-03) ----------
#
# gate_failopen() defaults its log to the REAL $HOME/.claude/gate-failopen.jsonl
# (the GATE_FAILOPEN_LOG assignment in hooks/lib/gate-failopen.sh). This file's
# setup() exported TURN_STATE_DIR but not
# GATE_FAILOPEN_LOG or HOME, so "am-i-done: fails OPEN when the reset hook
# never ran" (above) appended a row to PRODUCTION telemetry on every dev-time
# `bats` run of this file — the actual source of the rows that opened #210 (at
# least 11 of 13 as of this writing; root-caused via reflog + mtime-birth
# arithmetic, full detail in plans/REENTRY-issue210-gate-failopen.md and issue
# #210 comments). setup()/teardown() below now export both, closing the hole
# this test pins.

@test "root cause #210: this suite does not leak a fail-open record into a bystander's real HOME" {
  # Runs THIS FILE, filtered to the one test that reproduces the leak, as a
  # child bats process with HOME pointed at a throwaway dir and
  # GATE_FAILOPEN_LOG deliberately UNSET — i.e. exactly this file's own
  # setup(), exercising the hook's default log path. If setup() does not
  # export GATE_FAILOPEN_LOG, the child's fail-open write has nowhere else to
  # go and lands at $LEAK_HOME/.claude/gate-failopen.jsonl.
  LEAK_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/leakhome.XXXXXX")"
  mkdir -p "$LEAK_HOME/.claude"

  run env -u GATE_FAILOPEN_LOG HOME="$LEAK_HOME" \
    bats --filter '^am-i-done: fails OPEN when the reset hook never ran$' "$BATS_TEST_DIRNAME/gates.bats"

  # Sanity: the filter must have actually selected and run the one offending
  # test (TAP plan "1..1" + "ok 1"), or a wrong/empty selection would pass the
  # leak check below for no reason.
  [[ "$output" == *"1..1"* ]]
  [[ "$output" == *"ok 1 am-i-done: fails OPEN when the reset hook never ran"* ]]

  [ ! -e "$LEAK_HOME/.claude/gate-failopen.jsonl" ] || {
    echo "LEAK reproduced: $(cat "$LEAK_HOME/.claude/gate-failopen.jsonl")"
    rm -rf "$LEAK_HOME"
    false
  }

  rm -rf "$LEAK_HOME"
}

# ---------- #28: the message must name a form that RESOLVES ----------
#
# Shipped in a plugin, the invocable names are plugin-scoped
# (Skill(procedures:how-do-i)). A gate that DENIES while naming a bare
# `Skill(how-do-i)` sends the agent after a skill it cannot call: deny, retry,
# deny — a hard wedge with no exit. turn-state-record.sh already accepts both
# forms, so recognition was never the gap; only the messages were.

# A plugin tree with the hooks but NO skills/ — the 2026-08-07 wedge shape.
headless_plugin() {
  local tree
  tree="$(mktemp -d "${BATS_TMPDIR:-/tmp}/headless.XXXXXX")"
  mkdir -p "$tree/hooks"
  cp -R "$HOOKS/lib" "$tree/hooks/lib"
  cp "$HOOKS"/*.sh "$tree/hooks/"
  printf '%s' "$tree"
}

@test "how-do-i-gate: the deny names the plugin-scoped skill, not a bare name" {
  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"Skill(procedures:how-do-i)"* ]] \
    || { echo "deny does not name the resolvable form: $output"; false; }
  [[ "$output" != *"Skill(how-do-i)"* ]] \
    || { echo "deny still names the bare, unresolvable form: $output"; false; }
}

@test "am-i-done-gate: the block names the plugin-scoped skill, not a bare name" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"Skill(procedures:am-i-done)"* ]] \
    || { echo "block does not name the resolvable form: $output"; false; }
  [[ "$output" != *"Skill(am-i-done)"* ]] \
    || { echo "block still names the bare, unresolvable form: $output"; false; }
}

@test "how-do-i-gate: BOTH the bare and the plugin-scoped invocation satisfy it" {
  # The message may name only one form, but it must never name a form that
  # fails to satisfy. Both are accepted, so naming the scoped one is safe.
  local form
  for form in how-do-i procedures:how-do-i; do
    start_turn
    ran_skill "$form"
    run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
    [ -z "$output" ] || { echo "Skill($form) did NOT satisfy the gate: $output"; false; }
  done
}

@test "am-i-done-gate: BOTH the bare and the plugin-scoped invocation satisfy it" {
  local form
  for form in am-i-done procedures:am-i-done; do
    start_turn
    user_prompt
    assistant_tool Edit
    ran_skill "$form"
    run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
    [ -z "$output" ] || { echo "Skill($form) did NOT satisfy the gate: $output"; false; }
  done
}

@test "how-do-i-gate: an UNRESOLVABLE skill fails open and is RECORDED" {
  # Hooks present, skills absent. Denying here names a skill that cannot be
  # invoked, so the gate must release instead — and say so, or the wedge is
  # silent again.
  local tree; tree="$(headless_plugin)"
  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$tree/hooks/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"deny"* ]] \
    || { echo "gate denied while naming an unresolvable skill (hard wedge): $output"; false; }
  grep -q '"why":"skill-unresolvable"' "$GATE_FAILOPEN_LOG" \
    || { echo "wedge released but left no record: $(cat "$GATE_FAILOPEN_LOG" 2>/dev/null)"; false; }
  grep -q '"gate":"how-do-i"' "$GATE_FAILOPEN_LOG"
  rm -rf "$tree"
}

@test "am-i-done-gate: an UNRESOLVABLE skill fails open and is RECORDED" {
  local tree; tree="$(headless_plugin)"
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$tree/hooks/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"block"* ]] \
    || { echo "gate blocked while naming an unresolvable skill (hard wedge): $output"; false; }
  grep -q '"why":"skill-unresolvable"' "$GATE_FAILOPEN_LOG" \
    || { echo "wedge released but left no record: $(cat "$GATE_FAILOPEN_LOG" 2>/dev/null)"; false; }
  grep -q '"gate":"am-i-done"' "$GATE_FAILOPEN_LOG"
  rm -rf "$tree"
}

@test "the resolvability check does not make a healthy gate inert" {
  # The other half: with skills present the gate must still bite. A check that
  # released unconditionally would pass every test above and disable the gate.
  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"deny"* ]]
  [ ! -s "$GATE_FAILOPEN_LOG" ] \
    || { echo "a healthy install recorded a fail-open: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}
