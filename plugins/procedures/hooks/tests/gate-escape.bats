#!/usr/bin/env bats
# Escape-hatch policy: each gate has its own named switch, on by default, and
# turning one off leaves the others armed.
#
# Two layers are proved separately, because passing an env var into a script
# only proves the script reads a variable — the observable outcome is what the
# gate does with it:
#   1. ge_enabled() semantics (lib-level).
#   2. Each gate's OUTCOME with its switch off: no deny/block JSON, exit 0, and
#      an EMPTY fail-open log — a configured release is not a blind one, so it
#      must not enter that telemetry (contract in hooks/lib/gate-failopen.sh).
#
# Every "released" test is paired with an ARMED assertion on the same payload:
# a gate observed only passing is a gate observed doing nothing.
#
# Run: bats hooks/tests/gate-escape.bats

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

# ---------- ge_enabled semantics ----------

@test "escape: an unset switch leaves the gate ON" {
  run bash -c "unset CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE PROCEDURES_ENABLE_HOW_DO_I_GATE; . '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "0" ]
}

@test "escape: an empty switch leaves the gate ON" {
  run env PROCEDURES_ENABLE_HOW_DO_I_GATE="" bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "0" ]
}

@test "escape: false and 0 turn the gate OFF" {
  for v in false FALSE False 0; do
    run env PROCEDURES_ENABLE_HOW_DO_I_GATE="$v" bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
    [ "$output" = "1" ]
  done
}

@test "escape: true keeps the gate ON" {
  for v in true TRUE 1; do
    run env PROCEDURES_ENABLE_HOW_DO_I_GATE="$v" bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
    [ "$output" = "0" ]
  done
}

@test "escape: an unrecognised value leaves the gate ON" {
  # Only an explicit false disarms. A typo must fail toward the gate being on.
  for v in no off disabled nope FALSEY; do
    run env PROCEDURES_ENABLE_HOW_DO_I_GATE="$v" bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
    [ "$output" = "0" ]
  done
}

@test "escape: one switch does not affect another gate" {
  run env PROCEDURES_ENABLE_HOW_DO_I_GATE=false bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled AM_I_DONE_GATE; echo \$?"
  [ "$output" = "0" ]
  run env PROCEDURES_ENABLE_HOW_DO_I_GATE=false bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled FRONTMATTER_CHECK; echo \$?"
  [ "$output" = "0" ]
}

@test "escape: either switch saying false turns the gate off" {
  # The installed-plugin case, and the reason there is no precedence: the
  # option carries "default": true, so the harness exports it as `true` on
  # every hook invocation. If the option won, PROCEDURES_ENABLE_* could never
  # be observed on an installed plugin — the one-off override would work only
  # in a bare checkout, which is the case that does not need it.
  run env CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=true PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "1" ]
  run env CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=false PROCEDURES_ENABLE_HOW_DO_I_GATE=true \
    bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "1" ]
  run env CLAUDE_PLUGIN_OPTION_ENABLE_HOW_DO_I_GATE=true PROCEDURES_ENABLE_HOW_DO_I_GATE=true \
    bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  [ "$output" = "0" ]
}

@test "escape: the plain override works with the option at its exported default" {
  # An installed plugin's hook process sees the option at "default": true even
  # when the owner never opened the config dialog. That is the scenario the
  # one-off override exists for, so it is the one pinned here.
  run env CLAUDE_PLUGIN_OPTION_ENABLE_AM_I_DONE_GATE=true PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled AM_I_DONE_GATE; echo \$?"
  [ "$output" = "1" ]
}

@test "escape: the lib needs no external binary (PATH-empty safe)" {
  # how-do-i-gate sources this on the no-jq path, where PATH is emptied.
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    /bin/bash -c ". '$HOOKS/lib/gate-escape.sh'; ge_enabled HOW_DO_I_GATE; echo \$?"
  rm -rf "$EMPTY"
  [ "$output" = "1" ]
}

# ---------- gate outcomes ----------

@test "how-do-i-gate: armed by default, released by its own switch" {
  start_turn
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]

  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "how-do-i-gate: another gate's switch does not release it" {
  start_turn
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
}

@test "am-i-done-gate: armed by default, released by its own switch" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]

  start_turn
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "am-i-done-gate: another gate's switch does not release it" {
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [[ "$output" == *"AM-I-DONE"* ]]
}

@test "enforce-frontmatter: armed by default, released by its own switch" {
  ROOT="$HOME/.claude"
  mkdir -p "$ROOT/references/decisions"
  BAD="$ROOT/references/decisions/2026-01-01-no-frontmatter.md"
  printf '# no frontmatter here\n' > "$BAD"
  P="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BAD\"}}"

  run env KNOWLEDGE_ROOT="$ROOT" bash -c "echo '$P' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 2 ]

  run env KNOWLEDGE_ROOT="$ROOT" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    bash -c "echo '$P' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a switched-off gate IS recorded, in its own log" {
  # An unrecorded off-switch is invisible: nothing would distinguish an owner
  # debugging for an hour from a child session spawned with the gate off to
  # dodge review.
  start_turn
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  run jq -e '.gate == "HOW_DO_I_GATE" and .released_by == "PROCEDURES_ENABLE_HOW_DO_I_GATE" and (.ts | length > 0)' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

@test "an armed gate writes no escape record" {
  # Otherwise the log measures "this hook ran", not "a gate was switched off".
  start_turn
  run env CLAUDE_CODE_AGENT=technician GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

@test "a configured release is NOT recorded as a fail-open" {
  # gate-failopen.jsonl means "a gate released without deciding". An owner
  # exercising a switch decided — logging it makes the telemetry unreadable.
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
}

# ---------- the declared options ----------

@test "plugin.json declares one boolean switch per gate, defaulting to on" {
  # Asserted on the PARSED manifest: a grep over config source proves a string,
  # not a property. The option key IS the contract — the harness exports it to
  # hooks as CLAUDE_PLUGIN_OPTION_<KEY>, which is what gate-escape.sh reads.
  MANIFEST="$HOOKS/../.claude-plugin/plugin.json"
  # The key set is derived, not frozen: a hardcoded list here is the same
  # staleness gate-escape.sh refuses to carry.
  run jq -e '[.userConfig | to_entries[] | select(.key | startswith("enable_"))]
             | length >= 1
               and all(.[]; .value
                 | (.type == "boolean") and (.default == true)
                   and has("title") and has("description"))' "$MANIFEST"
  [ "$status" -eq 0 ]
  # No switch may be secret: a hidden gate-disable is exactly what an audit
  # needs to see.
  run jq -r '[.userConfig[] | select(.sensitive == true)] | length' "$MANIFEST"
  [ "$output" = "0" ]
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
  # "HOW_DO_I_GATE" into all three call sites would have passed the suite.
  start_turn
  user_prompt
  assistant_tool Edit
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_AM_I_DONE_GATE=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$STOP' | bash '$HOOKS/am-i-done-gate.sh'"
  [ "$status" -eq 0 ]
  run jq -e 'select(.gate == "AM_I_DONE_GATE") | .released_by == "PROCEDURES_ENABLE_AM_I_DONE_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  ROOT="$HOME/.claude"
  mkdir -p "$ROOT/references/decisions"
  BAD="$ROOT/references/decisions/2026-01-01-no-frontmatter.md"
  printf '# no frontmatter here\n' > "$BAD"
  P="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BAD\"}}"
  run env KNOWLEDGE_ROOT="$ROOT" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$P' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ]
  run jq -e 'select(.gate == "FRONTMATTER_CHECK") | .released_by == "PROCEDURES_ENABLE_FRONTMATTER_CHECK"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]
}

@test "an unreadable escape lib leaves every gate ARMED" {
  # The feature's central fail-safe, asserted in three hook comments and
  # previously pinned by nothing. Mutation runs on a COPY — reverting the real
  # tree is how a reviewer wrecked this worktree mid-review.
  # Lives under TURN_STATE_DIR so teardown() removes it even when an assertion
  # below aborts the test — a RETURN trap is not usable here, bats runs with
  # functrace so it fires on the first helper's return.
  COPY="$TURN_STATE_DIR/esc-copy"
  mkdir -p "$COPY"
  cp -r "$HOOKS" "$COPY/hooks"
  cp -r "$BATS_TEST_DIRNAME/../../scripts" "$COPY/scripts"
  chmod 000 "$COPY/hooks/lib/gate-escape.sh"

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
  ROOT="$HOME/.claude"
  mkdir -p "$ROOT/references/decisions"
  BAD="$ROOT/references/decisions/2026-01-01-unreadable-lib.md"
  printf '# no frontmatter here\n' > "$BAD"
  P="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BAD\"}}"
  run env KNOWLEDGE_ROOT="$ROOT" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    bash -c "echo '$P' | bash '$COPY/hooks/enforce-frontmatter.sh'"
  [ "$status" -eq 2 ]

  chmod 644 "$COPY/hooks/lib/gate-escape.sh"
}

@test "a released gate is recorded only when it would otherwise have fired" {
  # The log must count RELEASES, not hook invocations. Both payloads below are
  # ones the armed hook ignores anyway, so neither may write a row.
  start_turn
  # A subagent — this gate never binds subagents.
  P="{\"session_id\":\"$SID\",\"agent_id\":\"sub1\",\"tool_name\":\"Edit\",\"tool_input\":{}}"
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$P' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_ESCAPE_LOG" ]

  # A write far outside any record store.
  Q="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/not-a-record.txt\"}}"
  run env KNOWLEDGE_ROOT="$HOME/.claude" PROCEDURES_ENABLE_FRONTMATTER_CHECK=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
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
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" \
    bash -c "echo '$R' | bash '$HOOKS/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_ESCAPE_LOG" ]
}

@test "a degraded gate with its switch off is an escape, not a blind fail-open" {
  # gate_failopen never returns, so every degenerate path used to pre-empt the
  # switch — filing a deliberate release as blind, one row per tool call for a
  # whole session, inflating the very rate that log exists to measure.
  # No start_turn: no .turn marker => the reset-hook-never-ran path.
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GATE_FAILOPEN_LOG" ]
  run jq -e '.gate == "HOW_DO_I_GATE"' "$GATE_ESCAPE_LOG"
  [ "$status" -eq 0 ]

  # And with the escape lib itself unreadable, the degraded path must STILL
  # release. Without the ge_release_or_failopen fallback the undefined function
  # returns 127 and execution falls through into the deny — a gate denying on a
  # degraded path is the one outcome fail-open exists to prevent. Test 22 cannot
  # catch this: it asserts the deny.
  : > "$GATE_ESCAPE_LOG"; : > "$GATE_FAILOPEN_LOG"
  BROKE="$TURN_STATE_DIR/broke"
  mkdir -p "$BROKE"
  cp -r "$HOOKS" "$BROKE/hooks"
  chmod 000 "$BROKE/hooks/lib/gate-escape.sh"
  run env CLAUDE_CODE_AGENT=technician PROCEDURES_ENABLE_HOW_DO_I_GATE=false \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$BROKE/hooks/how-do-i-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
  chmod 644 "$BROKE/hooks/lib/gate-escape.sh"

  # Armed, same degraded state: still a blind fail-open, unchanged.
  : > "$GATE_FAILOPEN_LOG"
  : > "$GATE_ESCAPE_LOG"
  run env CLAUDE_CODE_AGENT=technician \
    GATE_ESCAPE_LOG="$GATE_ESCAPE_LOG" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  grep -q 'reset-hook-never-ran' "$GATE_FAILOPEN_LOG"
  [ ! -s "$GATE_ESCAPE_LOG" ]
}
