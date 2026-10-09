#!/usr/bin/env bats
# Escape-hatch policy: each gate has its own named switch with a per-key
# default, and moving one leaves the others where they were.
#   default OFF (soft gates): HOW_DO_I_GATE, AM_I_DONE_GATE, QUERY_SHAPE_GUARD —
#     only `true`/`1` arms them, and the arm is recorded as armed_by.
#   default ON (everything else, unknown keys included): only `false`/`0`
#     releases them, and the release is recorded as released_by.
#
# Two layers are proved separately, because passing an env var into a script
# only proves the script reads a variable — the observable outcome is what the
# gate does with it:
#   1. ge_enabled() semantics (lib-level).
#   2. Each gate's OUTCOME per switch state: unarmed/released = no deny/block
#      JSON, exit 0, and an EMPTY fail-open log; armed = the deny. A deviation
#      from a key's own default is not a blind release, so it must not enter
#      that telemetry (contract in hooks/lib/gate-failopen.sh).
#
# This suite is the home of the switch semantics, so setup() arms NOTHING:
# every test that needs an armed gate passes the variable itself. Every
# unarmed assertion is paired with an ARMED one on the same payload: an
# unarmed gate is silent whether or not it is correct, so silence alone proves
# nothing.
#
# Run: bats hooks/tests/gate-escape.bats

load helpers/common

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/esc.XXXXXX")"
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/esc-home.XXXXXX")"
  mkdir -p "$HOME/.claude"
  # Both logs pinned into the throwaway dir. gate-escape.sh defaults
  # GATE_ESCAPE_LOG to $HOME/.claude/gate-escape.jsonl exactly as
  # gate-failopen.sh does — leaving it unset is how this suite's sibling leaked
  # 11+ rows into production telemetry (orchard-codex#210).
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/gate-failopen.jsonl"
  export GATE_ESCAPE_LOG="$TURN_STATE_DIR/gate-escape.jsonl"
  export QUERY_GUARD_STATE_DIR="$TURN_STATE_DIR/qsg"
  # A developer shell (or a CI job) that exports a switch would flip results
  # silently; cleared by prefix (see helpers/common.bash).
  clear_gate_switches
  # The gate scripts exit early under sdk-cli; a caller's ambient value would
  # make every armed assertion pass vacuously.
  unset CLAUDE_CODE_ENTRYPOINT
  SID="bats-e-$$-$BATS_TEST_NUMBER"
  PAYLOAD_EDIT="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}"
  PROJ="$HOME/.claude/projects/-bats-e-$$-$BATS_TEST_NUMBER"
  mkdir -p "$PROJ"
  JSONL="$PROJ/$SID.jsonl"
  : > "$JSONL"
  STOP="{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}"
}

teardown() {
  rm -rf "$TURN_STATE_DIR" "$HOME" 2>/dev/null || true
}

start_turn() { printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"; }
user_prompt() { printf '{"type":"user","message":{"content":"do the thing"}}\n' >> "$JSONL"; }
assistant_tool() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s"}]}}\n' "$1" >> "$JSONL"
}

# ge <KEY> [VAR=value]... — ge_enabled's exit code, printed. Extra args are
# passed to `env`, so the caller names exactly the switches that are set.
ge() {
  local key="$1"; shift
  env "$@" bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled $key; echo \$?"
}

# hdi_gate [VAR=value]... / aid_gate [VAR=value]... — run the gate on the
# standard payload with exactly the named switches.
hdi_gate() {
  env CLAUDE_CODE_AGENT=technician "$@" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
}
aid_gate() {
  env CLAUDE_CODE_AGENT=technician "$@" \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
}

# A record-store write with no frontmatter: enforce-frontmatter must block it
# (exit 2) unless released. Sets BAD_PAYLOAD and FM_ROOT.
bad_record() {
  FM_ROOT="$HOME/.claude"
  mkdir -p "$FM_ROOT/references/decisions"
  BAD="$FM_ROOT/references/decisions/2026-01-01-no-frontmatter.md"
  printf '# no frontmatter here\n' > "$BAD"
  BAD_PAYLOAD="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BAD\"}}"
}
fm_gate() { # fm_gate [VAR=value]...
  env KNOWLEDGE_ROOT="$FM_ROOT" "$@" \
    bash -c "echo '$BAD_PAYLOAD' | bash '$HOOKS/enforce-frontmatter.sh'"
}

# ---------- ge_enabled semantics ----------

@test "escape: an unset switch leaves a default-off gate OFF and a default-on gate ON" {
  run ge HOW_DO_I_GATE
  [ "$output" = "1" ]
  run ge FRONTMATTER_CHECK
  [ "$output" = "0" ]
}

@test "escape: an empty switch leaves a default-off gate OFF and a default-on gate ON" {
  run ge HOW_DO_I_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE=""
  [ "$output" = "1" ]
  run ge FRONTMATTER_CHECK PROCEDURES_ENABLE_FRONTMATTER_CHECK=""
  [ "$output" = "0" ]
}

@test "escape: an unknown key defaults ON, like the other default-on keys" {
  # ge__default_off names the three soft gates and nothing else, so a key the
  # lib has never heard of must behave as default-on: a new hook that forgets
  # to register a polarity gets a gate that is armed, not silently absent.
  run ge SYNTHETIC_KEY
  [ "$output" = "0" ]
  run ge SYNTHETIC_KEY PROCEDURES_ENABLE_SYNTHETIC_KEY=false
  [ "$output" = "1" ]
}

@test "escape: false and 0 release a default-on gate" {
  for v in false FALSE False 0; do
    run ge FRONTMATTER_CHECK PROCEDURES_ENABLE_FRONTMATTER_CHECK="$v"
    [ "$output" = "1" ]
  done
}

@test "escape: false and 0 leave a default-off gate OFF, and record nothing" {
  # There is no 'release' for a gate that was never armed: an explicit false is
  # the resting state spelled out, not a deviation.
  for v in false 0; do
    run ge HOW_DO_I_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE="$v"
    [ "$output" = "1" ]
  done
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

@test "escape: true and 1 arm a default-off gate" {
  for v in true TRUE 1; do
    run ge HOW_DO_I_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE="$v"
    [ "$output" = "0" ]
  done
}

@test "escape: true and 1 leave a default-on gate ON" {
  for v in true TRUE 1; do
    run ge FRONTMATTER_CHECK PROCEDURES_ENABLE_FRONTMATTER_CHECK="$v"
    [ "$output" = "0" ]
  done
}

@test "escape: an unrecognised value leaves every key at its own default" {
  # Only the exact on/off spellings move a key. A typo must fail toward the
  # key's own default — never flip it.
  for v in no off disabled nope FALSEY TRUEISH; do
    run ge HOW_DO_I_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE="$v"
    [ "$output" = "1" ]
    run ge FRONTMATTER_CHECK PROCEDURES_ENABLE_FRONTMATTER_CHECK="$v"
    [ "$output" = "0" ]
  done
}

@test "escape: one switch does not affect another gate" {
  run ge AM_I_DONE_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [ "$output" = "1" ]
  run ge FRONTMATTER_CHECK PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [ "$output" = "0" ]
  run ge AM_I_DONE_GATE PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$output" = "1" ]
  run ge NUDGE PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$output" = "0" ]
}

@test "escape: either switch saying true arms a default-off gate" {
  # The installed-plugin case, and the reason there is no precedence: the
  # harness exports every option on every hook invocation, so for these gates
  # it always sees the manifest default `false`. If the option won, the
  # PROCEDURES_ENABLE_* one-off arm could never be observed on an installed
  # plugin — it would work only in a bare checkout, which does not need it.
  run ge HOW_DO_I_GATE CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=true PROCEDURES_ENABLE_HOW_DO_I_GATE=false
  [ "$output" = "0" ]
  run ge HOW_DO_I_GATE CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=false PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [ "$output" = "0" ]
  run ge HOW_DO_I_GATE CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=true PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [ "$output" = "0" ]
  run ge HOW_DO_I_GATE CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=false PROCEDURES_ENABLE_HOW_DO_I_GATE=false
  [ "$output" = "1" ]
}

@test "escape: either switch saying false releases a default-on gate" {
  # Same no-precedence rule, other polarity: the option carries `true` on an
  # installed plugin and the plain override must still be able to win.
  run ge FRONTMATTER_CHECK CLAUDE_PLUGIN_OPTION_ENABLE_FRONTMATTER_CHECK=true PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$output" = "1" ]
  run ge FRONTMATTER_CHECK CLAUDE_PLUGIN_OPTION_ENABLE_FRONTMATTER_CHECK=false PROCEDURES_ENABLE_FRONTMATTER_CHECK=true
  [ "$output" = "1" ]
  run ge FRONTMATTER_CHECK CLAUDE_PLUGIN_OPTION_ENABLE_FRONTMATTER_CHECK=true PROCEDURES_ENABLE_FRONTMATTER_CHECK=true
  [ "$output" = "0" ]
}

@test "escape: the plain override works with the option at its exported default" {
  # An installed plugin's hook process sees a default-off gate's option as
  # `false` even when the owner never opened the config dialog; a default-on
  # one as `true`. That is the scenario the one-off override exists for.
  run ge AM_I_DONE_GATE CLAUDE_PLUGIN_OPTION_ENABLE_AM_I_DONE_GATE=false PROCEDURES_ENABLE_AM_I_DONE_GATE=true
  [ "$output" = "0" ]
  run ge FRONTMATTER_CHECK CLAUDE_PLUGIN_OPTION_ENABLE_FRONTMATTER_CHECK=true PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$output" = "1" ]
}

@test "escape: the lib needs no external binary, recording included (PATH-empty safe)" {
  # how-do-i-gate sources this on the no-jq path, where PATH is emptied. Both
  # polarities are driven with a switch that DEVIATES, because only a deviation
  # reaches ge__record and its `date` call — an unset switch never would. The
  # row must still be written, with ts degraded to "unknown".
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" PROCEDURES_ENABLE_HOW_DO_I_GATE=true \
    /bin/bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "0" ]
  run env PATH="$EMPTY" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    /bin/bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled FRONTMATTER_CHECK; echo \$?"
  [ "$output" = "1" ]
  rm -rf "$EMPTY"
  [ "$(grep -c '"ts":"unknown"' "$GATE_ESCAPE_LOG")" = "2" ]
}

# ---------- gate outcomes ----------

@test "how-do-i-gate: silent when unarmed, denies when armed, silent again when switched off" {
  # The unarmed negative control, with its premise in the SAME test: the armed
  # call on this payload denies and records armed_by, so the silence that
  # follows cannot be the gate failing to reach its deny.
  start_turn
  export PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  run hdi_gate
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  run jq -e '.gate == "HOW_DO_I_GATE" and .armed_by == "PROCEDURES_ENABLE_HOW_DO_I_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  : > "$GATE_ESCAPE_LOG"
  unset PROCEDURES_ENABLE_HOW_DO_I_GATE
  run hdi_gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]

  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

@test "how-do-i-gate: another gate's switch neither releases nor arms it" {
  start_turn
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true PROCEDURES_ENABLE_AM_I_DONE_GATE=false
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  run hdi_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "am-i-done-gate: silent when unarmed, blocks when armed, silent again when switched off" {
  start_turn
  user_prompt
  assistant_tool Edit
  export PROCEDURES_ENABLE_AM_I_DONE_GATE=true
  run aid_gate
  [[ "$output" == *"AM-I-DONE"* ]]
  run jq -e '.gate == "AM_I_DONE_GATE" and .armed_by == "PROCEDURES_ENABLE_AM_I_DONE_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  # The block is once per turn, so re-open the turn: otherwise the unarmed call
  # is silent because the budget is spent, not because the gate is unarmed.
  : > "$GATE_ESCAPE_LOG"
  unset PROCEDURES_ENABLE_AM_I_DONE_GATE
  start_turn
  run aid_gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]

  start_turn
  run aid_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "am-i-done-gate: another gate's switch neither releases nor arms it" {
  start_turn
  user_prompt
  assistant_tool Edit
  run aid_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=true PROCEDURES_ENABLE_HOW_DO_I_GATE=false
  [[ "$output" == *"AM-I-DONE"* ]]
  start_turn
  run aid_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "enforce-frontmatter: armed by default, released by its own switch" {
  # Truthful "default": FRONTMATTER_CHECK is a default-ON key.
  bad_record
  run fm_gate
  [ "$status" -eq 2 ]
  run fm_gate PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an armed default-off gate IS recorded (armed_by), in its own log" {
  # An unrecorded arm is invisible: nothing would distinguish an owner
  # debugging for an hour from a child session spawned with the gate armed.
  start_turn
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  run jq -e '.gate == "HOW_DO_I_GATE" and .armed_by == "PROCEDURES_ENABLE_HOW_DO_I_GATE" and (.ts | length > 0)' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

@test "an arm through the option channel is recorded under the option's name" {
  start_turn
  run hdi_gate CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=true
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  run jq -e '.gate == "HOW_DO_I_GATE" and .armed_by == "CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

@test "a released default-on gate IS recorded (released_by), in its own log" {
  bad_record
  run fm_gate PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$status" -eq 0 ]
  run jq -e '.gate == "FRONTMATTER_CHECK" and .released_by == "PROCEDURES_ENABLE_FRONTMATTER_CHECK" and (.ts | length > 0)' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

@test "an unarmed gate writes no escape record" {
  # Otherwise the log measures "this hook ran", not "a gate was switched".
  start_turn
  run hdi_gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
  # Premise: the same payload, armed, is a deny and does write a row.
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  [ -s "$GATE_ESCAPE_LOG" ]
}

@test "a default-on gate left at its default writes no escape record" {
  bad_record
  run fm_gate
  [ "$status" -eq 2 ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

@test "an explicit false on a gate is NOT recorded as a fail-open, even on a degraded path" {
  # gate-failopen.jsonl means "a gate released without deciding". An owner
  # exercising a switch decided — logging it makes the telemetry unreadable.
  # For the default-off gates =false is the resting state, for a default-on
  # gate it is a release; neither is blind. The degraded path (no start_turn
  # => reset-hook-never-ran) is where a switched-off gate used to be misfiled
  # as blind, so that is where it is driven. Each gate has its own armed
  # premise: the SAME call armed does reach the fail-open.
  run aid_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=true
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  run jq -e 'select(.gate == "how-do-i" and .why == "reset-hook-never-ran")' "$GATE_FAILOPEN_LOG"
  [ "$status" -eq 0 ]
  : > "$GATE_FAILOPEN_LOG"
  run aid_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=false
  [ "$status" -eq 0 ]
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=false
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

# ---------- the declared options ----------

@test "plugin.json declares one boolean switch per gate, with polarity matching the lib" {
  # Asserted on the PARSED manifest: a grep over config source proves a string,
  # not a property. The option key IS the contract — the harness exports it to
  # hooks as CLAUDE_PLUGIN_OPTION_<KEY>, which is what gate-escape.sh reads.
  MANIFEST="$HOOKS/../.claude-plugin/plugin.json"
  # The key set is derived, not frozen: a hardcoded list here is the same
  # staleness gate-escape.sh refuses to carry.
  run jq -e '[.userConfig | to_entries[] | select(.key | startswith("enable_"))]
             | length >= 1
               and all(.[]; .value
                 | (.type == "boolean")
                   and has("title") and has("description"))' "$MANIFEST"
  [ "$status" -eq 0 ]
  # No switch may be secret: a hidden gate-disable is exactly what an audit
  # needs to see.
  run jq -r '[.userConfig[] | select(.sensitive == true)] | length' "$MANIFEST"
  [ "$output" = "0" ]
  # The manifest default is what the harness exports on every hook call, so it
  # must agree with the lib's own default. Polarity is read from the PUBLIC
  # behaviour, not a private helper: with no switch set, ge_enabled says off
  # (1) iff the lib treats the key as default-off, and then the manifest
  # default must be false.
  for k in $(jq -r '.userConfig | keys[] | select(startswith("enable_"))' "$MANIFEST"); do
    KEY="$(printf '%s' "${k#enable_}" | tr '[:lower:]' '[:upper:]')"
    run ge "$KEY"
    lib_default="$output"
    if [ "$KEY" = "EVOLVE_SWEEP" ]; then
      # KNOWN MISMATCH, exempt by name: the manifest default is false but the
      # lib treats EVOLVE_SWEEP as default-on (installed plugin: off; bare
      # checkout: on). Pinned as a mismatch so that fixing either side fails
      # here and removes the exemption.
      # https://github.com/drewdrewthis/claude-plugins/issues/220
      run jq -e '.userConfig.enable_evolve_sweep.default == false' "$MANIFEST"
      [ "$status" -eq 0 ]
      [ "$lib_default" = "0" ]
      continue
    fi
    if [ "$lib_default" = "1" ]; then want=false; else want=true; fi
    run jq -e --arg k "$k" --argjson want "$want" '.userConfig[$k].default == $want' "$MANIFEST"
    [ "$status" -eq 0 ]
  done
}

@test "every declared enable_* option is read by a hook" {
  # The manifest and the hooks are two halves of one contract; a declared
  # switch nothing reads is a dead knob that reads as armed.
  MANIFEST="$HOOKS/../.claude-plugin/plugin.json"
  # Non-empty FIRST: a `for` over an empty key list runs zero assertions and
  # reports ok, so without this the test passed with .userConfig deleted
  # entirely — vacuous in exactly the state it exists to detect.
  run jq -e '[.userConfig | keys[] | select(startswith("enable_"))] | length >= 1' "$MANIFEST"
  [ "$status" -eq 0 ]
  for k in $(jq -r '.userConfig | keys[] | select(startswith("enable_"))' "$MANIFEST"); do
    KEY="$(printf '%s' "${k#enable_}" | tr '[:lower:]' '[:upper:]')"
    # Hooks only — recursing would let a string in THIS file satisfy the
    # manifest-to-hook contract it is supposed to prove.
    run grep -lF "ge_enabled \"$KEY\"" "$HOOKS"/*.sh
    [ "$status" -eq 0 ]
  done
}

@test "every gate key a hook reads is declared in the manifest" {
  # The reverse direction. Without it: wire ge_enabled "NEW_GATE" into a hook,
  # forget the plugin.json entry, and zero manifest keys iterate for it — every
  # test passes while shipping a gate whose only off-switch is invisible in the
  # config dialog.
  MANIFEST="$HOOKS/../.claude-plugin/plugin.json"
  # Deliberately NOT `grep -P`: PCRE is a GNU extension. BSD grep (macOS,
  # FreeBSD) rejects -P outright, KEYS comes back empty, and the guard below
  # then fails the test for a toolchain reason while reporting a contract
  # breach. Match-then-strip is POSIX and reads the same on both.
  KEYS="$(grep -oh 'ge_enabled "[A-Z_]*"' "$HOOKS"/*.sh \
            | sed 's/.*"\([A-Z_]*\)"/\1/' | sort -u)"
  [ -n "$KEYS" ]
  for KEY in $KEYS; do
    OPT="enable_$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')"
    run jq -e --arg k "$OPT" '.userConfig | has($k)' "$MANIFEST"
    [ "$status" -eq 0 ]
  done
}

@test "each gate records under its OWN key" {
  # Only how-do-i's record was content-checked, so a copy-paste bug hardcoding
  # "HOW_DO_I_GATE" into all call sites would have passed the suite.
  start_turn
  user_prompt
  assistant_tool Edit
  run aid_gate PROCEDURES_ENABLE_AM_I_DONE_GATE=true
  [[ "$output" == *"AM-I-DONE"* ]]
  run jq -e 'select(.gate == "AM_I_DONE_GATE") | .armed_by == "PROCEDURES_ENABLE_AM_I_DONE_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  start_turn
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  run jq -e 'select(.gate == "HOW_DO_I_GATE") | .armed_by == "PROCEDURES_ENABLE_HOW_DO_I_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  # A reviewer write is the one shape this guard denies.
  QSG_PAYLOAD="$(jq -nc --arg sid "$SID" \
    '{session_id:$sid, agent_type:"procedures:work-reviewer", tool_name:"Write", tool_input:{file_path:"/tmp/x", content:"x"}}')"
  run env PROCEDURES_ENABLE_QUERY_SHAPE_GUARD=true \
    bash -c "echo '$QSG_PAYLOAD' | bash '$HOOKS/query-shape-guard.sh'"
  [[ "$output" == *"QUERY-SHAPE-GUARD"* ]]
  run jq -e 'select(.gate == "QUERY_SHAPE_GUARD") | .armed_by == "PROCEDURES_ENABLE_QUERY_SHAPE_GUARD"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  # The default-on key records the other direction, under its own name.
  bad_record
  run fm_gate PROCEDURES_ENABLE_FRONTMATTER_CHECK=false
  [ "$status" -eq 0 ]
  run jq -e 'select(.gate == "FRONTMATTER_CHECK") | .released_by == "PROCEDURES_ENABLE_FRONTMATTER_CHECK"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

# unreadable_escape_copy — a per-test COPY of the plugin whose escape lib is
# chmod 000, in COPY. Mutation runs on a copy — reverting the real tree is how
# a reviewer wrecked this worktree mid-review. Lives under TURN_STATE_DIR so
# teardown() removes it even when an assertion aborts the test — a RETURN trap
# is not usable here, bats runs with functrace so it fires on the first
# helper's return.
unreadable_escape_copy() {
  skip_if_root
  COPY="$TURN_STATE_DIR/esc-copy"
  mkdir -p "$COPY"
  cp -r "$HOOKS" "$COPY/hooks"
  cp -r "$BATS_TEST_DIRNAME/../../scripts" "$COPY/scripts"
  # skills/ too: both gates fail OPEN when they cannot read the SKILL.md they
  # are about to name (the "skill-unresolvable" proxy — denying while naming an
  # unresolvable skill is a hard wedge). A sandbox without skills/ therefore
  # releases for that reason and never reaches the switch, which would make
  # this test pass or fail for the wrong reason.
  cp -r "$BATS_TEST_DIRNAME/../../skills" "$COPY/skills"
  chmod 000 "$COPY/hooks/lib/gate-escape.sh"
}

@test "an unreadable escape lib makes every gate deny, even with its switch set to false" {
  # The feature's central fail-safe, asserted in three hook comments and
  # previously pinned by nothing. For the two default-off gates =false is the
  # resting state, so this is a deny the owner did not ask for: see the
  # contract question pinned in the next test.
  unreadable_escape_copy

  start_turn
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$COPY/hooks/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]

  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    bash -c "echo '$STOP' | bash '$COPY/hooks/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]

  # The third hook. Omitting it let a removed `declare -F` guard in
  # enforce-frontmatter ship with all 23 tests green.
  bad_record
  run env KNOWLEDGE_ROOT="$FM_ROOT" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    bash -c "echo '$BAD_PAYLOAD' | bash '$COPY/hooks/enforce-frontmatter.sh'"
  [ "$status" -eq 2 ]

  chmod 644 "$COPY/hooks/lib/gate-escape.sh"
}

@test "an unreadable escape lib makes the default-off gates deny with NO switch set (open contract question)" {
  # CONTRACT QUESTION, not settled: the default-off gates are OFF at rest, yet
  # with the escape lib unreadable and nothing set they deny. Pinned as today's
  # behaviour so that deciding it either way changes this test on purpose.
  # https://github.com/drewdrewthis/claude-plugins/issues/220
  unreadable_escape_copy

  start_turn
  run env CLAUDE_CODE_AGENT=technician \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$COPY/hooks/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]

  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician \
    bash -c "echo '$STOP' | bash '$COPY/hooks/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]

  chmod 644 "$COPY/hooks/lib/gate-escape.sh"
}

@test "a switch is recorded only when the gate would otherwise have fired" {
  # The log must count DEVIATIONS THAT MATTER, not hook invocations. Every
  # payload below is one the gate ignores anyway, so none may write a row —
  # including with the switch in its deviating position.
  start_turn
  # A subagent — this gate never binds subagents. Armed on purpose: an unarmed
  # gate writes nothing for any payload, which would prove nothing here.
  P="{\"session_id\":\"$SID\",\"agent_id\":\"sub1\",\"tool_name\":\"Edit\",\"tool_input\":{}}"
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=true \
    bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_ESCAPE_LOG" ]

  # A write far outside any record store.
  Q="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/not-a-record.txt\"}}"
  run env KNOWLEDGE_ROOT="$HOME/.claude" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    bash -c "echo '$Q' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_ESCAPE_LOG" ]

  # A .md INSIDE the root that is not a record — CLAUDE.md, a README, an
  # agent file. This clears the *.md and under-$ROOT filters and is stopped
  # only by the linter's own record predicate, so a switch checked above that
  # predicate logs a release nothing was going to block.
  mkdir -p "$HOME/.claude"
  printf '# just a readme\n' > "$HOME/.claude/README.md"
  R="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HOME/.claude/README.md\"}}"
  run env KNOWLEDGE_ROOT="$HOME/.claude" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    bash -c "echo '$R' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

# gate_failopen never returns, so every degenerate path used to pre-empt the
# switch — filing a deliberate release as blind, one row per tool call for a
# whole session, inflating the very rate that log exists to measure.
# No start_turn in the three tests below: no .turn marker => the
# reset-hook-never-ran path. (gate-failopen.bats carries the per-gate negative
# controls for the unarmed half.)

@test "a degraded gate is silent when unarmed or switched off" {
  for sw in "" "PROCEDURES_ENABLE_HOW_DO_I_GATE=false"; do
    run hdi_gate $sw
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$GATE_FAILOPEN_LOG" ]
    [ ! -s "$GATE_ESCAPE_LOG" ]
  done
}

@test "a degraded gate with an unreadable escape lib still releases, recording the blind fail-open" {
  # With the escape lib itself unreadable, the degraded path must STILL
  # release. Without the ge_release_or_failopen fallback the undefined function
  # returns 127 and execution falls through into the deny — a gate denying on a
  # degraded path is the one outcome fail-open exists to prevent. The
  # unreadable-lib tests above cannot catch this: they assert the deny.
  skip_if_root
  BROKE="$TURN_STATE_DIR/broke"
  mkdir -p "$BROKE"
  cp -r "$HOOKS" "$BROKE/hooks"
  chmod 000 "$BROKE/hooks/lib/gate-escape.sh"
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$BROKE/hooks/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
  chmod 644 "$BROKE/hooks/lib/gate-escape.sh"
}

@test "a degraded gate is a blind fail-open when armed, and the arm itself is recorded" {
  run hdi_gate PROCEDURES_ENABLE_HOW_DO_I_GATE=true
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
  run jq -e '.gate == "HOW_DO_I_GATE" and .armed_by == "PROCEDURES_ENABLE_HOW_DO_I_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}
