#!/usr/bin/env bats
# Tests for hooks/decision-ask-guard.sh - PreToolUse deny of a Discord reply that asks
# the owner to decide items not marked one-way-door/values-laden with a recommendation.
#
# Coverage map:
#   deny    unmarked/partly-marked/negated-marker lists, single asks, ask phrasings
#           (should we, can you approve, ok to, your pick, thoughts?, ...)
#   allow   status reports, past-tense "your call/decision/approval", fully marked
#           lists, status lists before/after a marked ask, "let me know if you have..."
#   other   non-reply tool, empty text -> empty output, exit 0
#   open    invalid JSON, no jq, or no python3 on PATH -> fails open (empty stdout,
#           exit 0; the tool miss is logged to stderr)
#   bash3   every hook run goes through /bin/bash (3.2 on the macOS CI leg)
#   wiring  hooks.json is valid JSON and its command resolves to the script
#
# Run: bats hooks/tests/decision-ask-guard.bats

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$PLUGIN/hooks/decision-ask-guard.sh"
}

reply_json() { # text
  jq -n --arg t "$1" '{hook_event_name:"PreToolUse",tool_name:"mcp__plugin_discord_discord__reply",tool_input:{chat_id:"1",text:$t}}'
}

# /bin/bash on purpose: it is 3.2 on macOS, so the macOS CI leg proves the hook has
# no bash-4+ syntax; on Linux it is just the system bash.
run_hook() { run bash -c 'printf "%s" "$1" | /bin/bash "$2"' _ "$1" "$HOOK"; }

assert_denied() { # text
  run_hook "$(reply_json "$1")"
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = deny ]
  [[ "$output" == *proc.research-think.decide* ]]
}

assert_allowed() { # text
  run_hook "$(reply_json "$1")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unmarked inline list -> deny" {
  assert_denied "Decisions for you: 1) merge 8501? 2) stop the devtool slot?"
}

@test "marked inline list -> empty" {
  assert_allowed "Decisions for you: 1) merge 8501? one-way-door, I recommend merge. 2) stop the devtool slot? values-laden, recommend stop."
}

@test "one item unmarked -> deny" {
  assert_denied "Decisions for you: 1) merge 8501? one-way-door, I recommend merge. 2) stop the devtool slot?"
}

@test "unmarked bullets -> deny" {
  assert_denied $'Decisions for you:\n- merge 8501?\n- stop the devtool slot?'
}

@test "marked bullets -> empty" {
  assert_allowed $'Decisions for you:\n- merge 8501? one-way-door, I recommend merge.\n- stop the devtool slot? values-laden, my rec: stop.'
}

@test "status report -> empty" {
  assert_allowed "Fleet status: 3 workers green. PR 8501 merged. Devtool slot stopped."
}

@test "single ask, no list -> deny" {
  assert_denied "Want me to restart the technician?"
}

@test "non-question want-me-to -> empty" {
  assert_allowed "Fixed it. If you want me to change it later, say so."
}

@test "past your-decision -> empty" {
  assert_allowed "Done: merged 8501 per your decision yesterday."
}

@test "past your-approval -> empty" {
  assert_allowed "Merged after your approval. Slot stopped."
}

@test "your-call phone call -> empty" {
  assert_allowed "After your call with the vendor I updated the plan."
}

@test "reported want-me-to -> empty" {
  assert_allowed "You said you want me to stop pinging, so I stopped."
}

@test "status list before marked ask -> empty" {
  assert_allowed $'Status:\n- 8501 merged\n- slot stopped\n\nDecision for you: delete prod DB? one-way-door. I recommend no.'
}

@test "inline N. does not split -> empty" {
  assert_allowed "Decision for you: rotate the key? one-way-door. Recommendation: rotate on Monday at 9. Reason: low traffic."
}

@test "need-from-you bullets -> deny" {
  assert_denied $'What I need from you:\n- merge 8501?\n- stop devtool slot?'
}

@test "pending-on-you numbered -> deny" {
  assert_denied $'Pending on you:\n1. merge 8501\n2. stop devtool slot'
}

@test "let-me-know-if -> deny" {
  assert_denied "Let me know if I should merge 8501 or stop the slot."
}

@test "should-we -> deny" {
  assert_denied "Should we merge 8501?"
}

@test "can-you-approve -> deny" {
  assert_denied "Can you approve PR 8501?"
}

@test "yes/no -> deny" {
  assert_denied "Merge 8501? (yes/no)"
}

@test "which-do-you-prefer -> deny" {
  assert_denied "Which do you prefer: restart the technician or leave it?"
}

@test "let-me-know-if-you-want -> deny" {
  assert_denied "Let me know if you want the devtool slot stopped."
}

@test "past per-your-call -> empty" {
  assert_allowed "Per your call yesterday, I merged 8501."
}

@test "let-me-know-if-you-have -> empty" {
  assert_allowed "Merged 8501 and stopped the slot. Let me know if you have questions."
}

@test "let-me-know-if-anything -> empty" {
  assert_allowed "All done. Let me know if anything looks off."
}

@test "can-i-help -> empty" {
  assert_allowed "Can I help with anything else?"
}

@test "approved past + any questions -> empty" {
  assert_allowed "I approved the PR and merged it, any questions?"
}

@test "waiting-on-your noun -> empty" {
  assert_allowed "Fixed the waiting on your build issue; CI green."
}

@test "status list after marked ask -> empty" {
  assert_allowed $'Decision for you: drop prod table? one-way-door, I recommend keep.\n\nStatus:\n- 8501 merged\n- slot stopped'
}

@test "thoughts? -> deny" {
  assert_denied "Merge 8501? Stop the devtool slot? Thoughts?"
}

@test "what-do-you-think -> deny" {
  assert_denied "What do you think: merge 8501 or wait?"
}

@test "tell-me-which -> deny" {
  assert_denied "Tell me which: merge 8501 or wait."
}

@test "parenthetical your-call -> deny" {
  assert_denied $'Remaining work:\n- merge 8501 (your call)\n- stop devtool slot (your call)'
}

@test "first bullet holding the ask is scored -> deny" {
  assert_denied $'Remaining work:\n- merge 8501 (your call)\n- stop devtool slot (your call) one-way-door, I recommend stop'
}

@test "marked parenthetical your-call -> empty" {
  assert_allowed $'Remaining work:\n- merge 8501 (your call) one-way-door, I recommend merge\n- stop devtool slot (your call) values-laden, recommend stop'
}

@test "n't negated marker -> deny" {
  assert_denied "Decisions for you: 1) merge 8501? isn't one-way-door but I recommend merge. 2) stop slot? values-laden, recommend stop."
}

@test "ok-to -> deny" {
  assert_denied "OK to restart the technician?"
}

@test "your-pick -> deny" {
  assert_denied "Your pick: merge 8501 or wait?"
}

@test "negated marker -> deny" {
  assert_denied "Decisions for you: 1) merge 8501? not one-way-door, I recommend merge. 2) stop slot? values-laden, recommend stop."
}

@test "footer does not rescue last item -> deny" {
  assert_denied $'Decisions for you:\n- merge 8501? one-way-door, recommend merge.\n- stop slot?\n\nI recommend both, values-laden.'
}

@test "empty text -> empty" {
  assert_allowed ""
}

@test "Bash tool -> empty, exit 0" {
  run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty text -> empty, exit 0" {
  assert_allowed ""
}

@test "deny reason points at the decide skill" {
  run_hook "$(reply_json "Should we merge 8501?")"
  [[ "$output" == *"/decide:decide"* ]]
}

@test "invalid json -> empty, exit 0" {
  out="$(printf '%s' 'not json{' | /bin/bash "$HOOK" 2>"$BATS_TEST_TMPDIR/err")"
  rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
}

@test "no jq on PATH -> fails open: exit 0, no stdout, stderr names the miss" {
  err="$BATS_TEST_TMPDIR/err"
  out="$(printf '%s' "$(reply_json "Should we merge 8501?")" | PATH=/nonexistent /bin/bash "$HOOK" 2>"$err")"
  rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  grep -q "jq missing, failing open" "$err"
}

@test "no python3 on PATH -> fails open: exit 0, no stdout, stderr names the miss" {
  err="$BATS_TEST_TMPDIR/err"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v jq)" "$bin/jq"
  out="$(printf '%s' "$(reply_json "Should we merge 8501?")" | PATH="$bin" /bin/bash "$HOOK" 2>"$err")"
  rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  grep -q "python3 missing, failing open" "$err"
}

@test "hooks.json is valid and its command resolves to the script" {
  jq empty "$PLUGIN/hooks/hooks.json"
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN/hooks/hooks.json")"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$PLUGIN/hooks/hooks.json")" = "mcp__plugin_discord_discord__reply" ]
  resolved="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN}"
  resolved="${resolved#bash }"
  resolved="${resolved//\"/}"
  [ -x "$resolved" ]
  [ "$resolved" = "$HOOK" ]
}
