#!/usr/bin/env bats
# Tests for hooks/guard-general-purpose.sh — PreToolUse deny of the general-purpose subagent.
#
# Coverage map:
#   deny    Agent/Task with subagent_type general-purpose (any case) or none; the
#           reason names the delegation plugin and an existing route-delegation.sh
#   allow   any other subagent_type, any other tool -> empty output, exit 0
#   open    invalid JSON, or no jq on PATH -> fails open (empty stdout, exit 0; jq miss logged to stderr)
#   bash3   every hook run goes through /bin/bash (3.2 on the macOS CI leg)
#   wiring  hooks.json is valid JSON and its command resolves to the script
#
# Run: bats hooks/tests/guard-general-purpose.bats

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$PLUGIN/hooks/guard-general-purpose.sh"
}

payload() { # tool_name, [subagent_type]
  jq -n --arg t "$1" --arg s "${2-}" \
    '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:({prompt:"x"}+(if $s=="" then {} else {subagent_type:$s} end))}'
}

# /bin/bash on purpose: it is 3.2 on macOS, so the macOS CI leg proves the hook has
# no bash-4+ syntax (e.g. ${var,,}); on Linux it is just the system bash.
run_hook() { run bash -c 'printf "%s" "$1" | /bin/bash "$2"' _ "$1" "$HOOK"; }

assert_denied() {
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = deny ]
}

@test "Agent general-purpose -> deny, reason names the delegation plugin" {
  run_hook "$(payload Agent general-purpose)"
  assert_denied
  [[ "$output" == *"blocked by the delegation plugin"* ]]
}

@test "Agent General-Purpose -> deny" {
  run_hook "$(payload Agent General-Purpose)"
  assert_denied
}

@test "Task general-purpose -> deny" {
  run_hook "$(payload Task general-purpose)"
  assert_denied
}

@test "Agent without subagent_type -> deny" {
  run_hook "$(payload Agent)"
  assert_denied
}

@test "allowed subagent types -> empty, exit 0" {
  for t in coder fork Explore; do
    run_hook "$(payload Agent "$t")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "tool Bash -> empty, exit 0" {
  run_hook "$(payload Bash)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid json -> empty, exit 0" {
  run_hook 'not json{'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no jq on PATH -> fails open: exit 0, no stdout, stderr names the miss" {
  err="$BATS_TEST_TMPDIR/err"
  out="$(printf '%s' "$(payload Agent general-purpose)" | PATH=/nonexistent /bin/bash "$HOOK" 2>"$err")"
  rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  grep -q "jq missing, failing open" "$err"
}

@test "reason names the built-in fallbacks" {
  run_hook "$(payload Agent general-purpose)"
  [[ "$output" == *"Explore"* && "$output" == *"Plan"* && "$output" == *"fork"* ]]
}

@test "hooks.json is valid and its command resolves to the script" {
  jq empty "$PLUGIN/hooks/hooks.json"
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN/hooks/hooks.json")"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$PLUGIN/hooks/hooks.json")" = "Agent|Task" ]
  resolved="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN}"
  resolved="${resolved#bash }"
  resolved="${resolved//\"/}"
  [ -x "$resolved" ]
  [ "$resolved" = "$HOOK" ]
}

@test "reason's route-delegation.sh path exists" {
  run_hook "$(payload Agent general-purpose)"
  reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")"
  path="$(sed -n 's/.*bash "\([^"]*route-delegation\.sh\)".*/\1/p' <<<"$reason")"
  [ -f "$path" ]
}
