#!/usr/bin/env bats
# Tests for the gate libraries: turn-state, gate-audience, gate-allowlist.
#
# These are the shared units the three gates compose. Testing them directly
# means each gate's own suite only has to prove POLICY, not storage or parsing.
#
# Run: bats hooks/tests/gate-libs.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib"
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ts.XXXXXX")"
  SID="bats-$$-$BATS_TEST_NUMBER"
}

teardown() {
  rm -rf "$TURN_STATE_DIR" 2>/dev/null || true
}

# ---------- turn-state ----------

@test "turn-state: a fresh session has no turn started" {
  source "$LIB/turn-state.sh"
  run ts_turn_started "$SID"
  [ "$status" -ne 0 ]
}

@test "turn-state: reset stamps the turn marker" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  run ts_turn_started "$SID"
  [ "$status" -eq 0 ]
}

@test "turn-state: mark then is_marked" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  run ts_is_marked "$SID" how_do_i
  [ "$status" -ne 0 ]
  ts_mark "$SID" how_do_i
  run ts_is_marked "$SID" how_do_i
  [ "$status" -eq 0 ]
}

@test "turn-state: reset clears a key it does not enumerate" {
  # Regression: ts_reset hard-coded three keys, so am_i_done_asked survived
  # every turn and demoted am-i-done to once-per-SESSION.
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" am_i_done_asked
  ts_mark "$SID" some_future_key
  ts_reset "$SID"
  run ts_is_marked "$SID" am_i_done_asked; [ "$status" -ne 0 ]
  run ts_is_marked "$SID" some_future_key; [ "$status" -ne 0 ]
  # ...but the turn sentinel must survive, or every gate fails open.
  run ts_turn_started "$SID"; [ "$status" -eq 0 ]
}

@test "turn-state: reset clears flags from the previous turn" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" how_do_i
  ts_mark "$SID" am_i_done
  ts_reset "$SID"
  run ts_is_marked "$SID" how_do_i;  [ "$status" -ne 0 ]
  run ts_is_marked "$SID" am_i_done; [ "$status" -ne 0 ]
}

@test "turn-state: flags are independent (no lost update between keys)" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" how_do_i &
  ts_mark "$SID" am_i_done &
  wait
  run ts_is_marked "$SID" how_do_i;  [ "$status" -eq 0 ]
  run ts_is_marked "$SID" am_i_done; [ "$status" -eq 0 ]
}

@test "turn-state: session id is sanitised against traversal" {
  source "$LIB/turn-state.sh"
  run ts_session_id '{"session_id":"../../etc/passwd"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *".."* ]]
  [[ "$output" != *"/"* ]]
}

@test "turn-state: missing session id falls back to a stable bucket" {
  source "$LIB/turn-state.sh"
  run ts_session_id '{}'
  [ "$output" = "unknown" ]
}

# ---------- gate-audience ----------

@test "audience: a delegated subagent is never gated" {
  source "$LIB/gate-audience.sh"
  P='{"agent_id":"abc123"}'
  run ga_is_subagent "$P";   [ "$status" -eq 0 ]
  run ga_binds_main "$P";    [ "$status" -ne 0 ]
}

@test "audience: every non-subagent payload binds" {
  source "$LIB/gate-audience.sh"
  run ga_binds_main '{}'
  [ "$status" -eq 0 ]
  run ga_binds_main '{"agent_id":"abc"}'
  [ "$status" -ne 0 ]
}

# ---------- gate-allowlist ----------

@test "allowlist: Skill is always the compliance path" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Skill '{"tool_name":"Skill"}'
  [ "$status" -eq 0 ]
}

@test "allowlist: Agent is allowed so a delegating skill cannot deadlock" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Agent '{"tool_name":"Agent"}'
  [ "$status" -eq 0 ]
}

@test "allowlist: Read under references/procedures is allowed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Read '{"tool_input":{"file_path":"/home/u/.claude/references/procedures/x/PROCEDURE.md"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: traversal out of the procedures tree is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Read '{"tool_input":{"file_path":"/x/references/procedures/../../CLAUDE.md"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: read-only discovery Bash is allowed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"grep -r foo references/procedures/"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: destructive Bash merely MENTIONING the surface is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"rm -rf references/procedures/"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: an ordinary Edit is not the compliance path" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Edit '{"tool_input":{"file_path":"/tmp/x"}}'
  [ "$status" -ne 0 ]
}
