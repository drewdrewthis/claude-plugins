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
  run ts_is_marked "$SID" respond
  [ "$status" -ne 0 ]
  ts_mark "$SID" respond
  run ts_is_marked "$SID" respond
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
  ts_mark "$SID" respond
  ts_mark "$SID" how_do_i
  ts_mark "$SID" am_i_done
  ts_reset "$SID"
  run ts_is_marked "$SID" respond;   [ "$status" -ne 0 ]
  run ts_is_marked "$SID" how_do_i;  [ "$status" -ne 0 ]
  run ts_is_marked "$SID" am_i_done; [ "$status" -ne 0 ]
}

@test "turn-state: flags are independent (no lost update between keys)" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" respond &
  ts_mark "$SID" how_do_i &
  ts_mark "$SID" am_i_done &
  wait
  run ts_is_marked "$SID" respond;   [ "$status" -eq 0 ]
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
  run ga_binds_respond "$P"; [ "$status" -ne 0 ]
  run ga_binds_main "$P";    [ "$status" -ne 0 ]
}

@test "audience: respond binds the assistant" {
  source "$LIB/gate-audience.sh"
  CLAUDE_CODE_AGENT=assistant run ga_binds_respond '{}'
  [ "$status" -eq 0 ]
}

@test "audience: respond does NOT bind the default interactive session (agent unset)" {
  # Issue #197: the default interactive session is how-do-i-gated but NOT
  # respond-gated. Treating unset as "assistant" gates every worker and bare
  # shell that launches without --agent.
  run env -u CLAUDE_CODE_AGENT bash -c "source '$LIB/gate-audience.sh'; ga_binds_respond '{}'"
  [ "$status" -ne 0 ]
}

@test "audience: how-do-i DOES bind the default interactive session" {
  run env -u CLAUDE_CODE_AGENT bash -c "source '$LIB/gate-audience.sh'; ga_binds_main '{}'"
  [ "$status" -eq 0 ]
}

@test "audience: respond does NOT bind a named non-assistant agent" {
  source "$LIB/gate-audience.sh"
  run env CLAUDE_CODE_AGENT=technician bash -c "source '$LIB/gate-audience.sh'; ga_binds_respond '{}'"
  [ "$status" -ne 0 ]
}

@test "audience: how-do-i binds every main agent, named or not" {
  for a in technician orchardist support lead assistant; do
    run env CLAUDE_CODE_AGENT="$a" bash -c "source '$LIB/gate-audience.sh'; ga_binds_main '{}'"
    [ "$status" -eq 0 ]
  done
  run env -u CLAUDE_CODE_AGENT bash -c "source '$LIB/gate-audience.sh'; ga_binds_main '{}'"
  [ "$status" -eq 0 ]
}

# ---------- gate-audience: turn trigger ----------
#
# Owner directive 2026-08-05: /respond binds only a DIRECT message from him.
# Tag shapes below are verbatim from real transcripts.

@test "trigger: a plain terminal prompt is a direct owner message" {
  source "$LIB/gate-audience.sh"
  run ga_prompt_is_direct_owner "roll the notepad and start the day"
  [ "$status" -eq 0 ]
}

@test "trigger: a task-notification is not a direct owner message" {
  source "$LIB/gate-audience.sh"
  run ga_prompt_is_direct_owner '<task-notification status="completed">coder finished</task-notification>'
  [ "$status" -ne 0 ]
}

@test "trigger: another agent's channel message is not a direct owner message" {
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:discord:discord" chat_id="1515808689716465754" message_id="1531261186106986507" user="Clara" user_id="1515784888681238608" ts="2026-07-27T11:25:16.225Z">reflect posted</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -ne 0 ]
}

@test "trigger: the owner's own discord message binds, by name or by id alone" {
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:discord:discord" chat_id="1" message_id="2" user="drewdrewthis" user_id="805967286547775489" ts="t">status?</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -eq 0 ]
  # Id alone suffices: a display-name change must not silently exempt him.
  Q='<channel source="plugin:discord:discord" chat_id="1" message_id="2" user="someNewNick" user_id="805967286547775489" ts="t">status?</channel>'
  run ga_prompt_is_direct_owner "$Q"
  [ "$status" -eq 0 ]
  # ...and so does the name alone, for a tag carrying no user_id.
  R='<channel source="plugin:discord:discord" chat_id="1" user="drewdrewthis" ts="t">status?</channel>'
  run ga_prompt_is_direct_owner "$R"
  [ "$status" -eq 0 ]
}

@test "trigger: telegram is DM-locked to the owner, so any telegram tag binds" {
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:telegram:telegram" chat_id="1650037651" message_id="9" user="operator" ts="t">ping</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -eq 0 ]
}

@test "trigger: his message batched with other agents' still binds" {
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:discord:discord" chat_id="1" message_id="1" user="Clara" user_id="1515784888681238608" ts="t">a</channel>
<channel source="plugin:discord:discord" chat_id="1" message_id="2" user="drewdrewthis" user_id="805967286547775489" ts="t">b</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -eq 0 ]
}

@test "trigger: message text quoting a task-notification marker cannot exempt him" {
  # Ordering guard: owner-presence is decided BEFORE the marker scan, so text
  # he sends can only ever over-gate, never turn the gate off.
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:discord:discord" chat_id="1" user="drewdrewthis" user_id="805967286547775489" ts="t">why did <task-notification fire?</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -eq 0 ]
  # Same text from another agent stays exempt — it was never his turn.
  Q='<channel source="plugin:discord:discord" chat_id="1" user="Clara" user_id="1515784888681238608" ts="t">why did <task-notification fire?</channel>'
  run ga_prompt_is_direct_owner "$Q"
  [ "$status" -ne 0 ]
}

@test "trigger: an unclassifiable channel tag falls open to binding" {
  source "$LIB/gate-audience.sh"
  # Unterminated tag.
  run ga_prompt_is_direct_owner '<channel source="plugin:discord:discord" user="Clara'
  [ "$status" -eq 0 ]
  # No sender attribute at all.
  run ga_prompt_is_direct_owner '<channel source="plugin:discord:discord" chat_id="1">x</channel>'
  [ "$status" -eq 0 ]
  # Empty prompt.
  run ga_prompt_is_direct_owner ""
  [ "$status" -eq 0 ]
}

@test "trigger: an adjacent attribute cannot impersonate user=" {
  source "$LIB/gate-audience.sh"
  P='<channel source="plugin:discord:discord" reply_to_user="drewdrewthis" user="Clara" user_id="1515784888681238608" ts="t">x</channel>'
  run ga_prompt_is_direct_owner "$P"
  [ "$status" -ne 0 ]
}

@test "trigger: the owner identity set is env-configurable" {
  T='<channel source="plugin:discord:discord" user="Clara" user_id="1515784888681238608" ts="t">x</channel>'
  D='<channel source="plugin:discord:discord" user="drewdrewthis" user_id="805967286547775489" ts="t">x</channel>'
  run env RESPOND_DIRECT_USERS="Clara" bash -c "source '$LIB/gate-audience.sh'; ga_prompt_is_direct_owner '$T'"
  [ "$status" -eq 0 ]
  run env RESPOND_DIRECT_USERS="Clara" bash -c "source '$LIB/gate-audience.sh'; ga_prompt_is_direct_owner '$D'"
  [ "$status" -ne 0 ]
  # Comma-separated is accepted too.
  run env RESPOND_DIRECT_USERS="Clara,Rexxy" bash -c "source '$LIB/gate-audience.sh'; ga_prompt_is_direct_owner '$T'"
  [ "$status" -eq 0 ]
}

@test "trigger: tag attributes are read by name, not by position" {
  source "$LIB/gate-audience.sh"
  run ga_tag_attr ' source="plugin:discord:discord" user="Clara" user_id="42"' user
  [ "$output" = "Clara" ]
  run ga_tag_attr ' source="plugin:discord:discord" user="Clara" user_id="42"' user_id
  [ "$output" = "42" ]
  run ga_tag_attr ' source="x" user="Clara"' ts
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
