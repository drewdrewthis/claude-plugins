#!/usr/bin/env bats
# Tests for hooks/improve-nudge.sh — UserPromptSubmit one-line /improve nudge.
#
# Coverage map:
#   nudge   a plan/design/proposal/PR word plus an act-on-it word, or a GitHub PR
#           URL -> exactly the one nudge line, exit 0
#   silent  an artifact word with no act word, an act word with no artifact word,
#           words that only contain "pr"/"plan" (sprint, planet), a prompt that
#           already names /improve, a subagent prompt, the off-switch
#   open    invalid JSON, no prompt, or no jq on PATH -> empty output, exit 0
#   bash3   every hook run goes through /bin/bash (3.2 on the macOS CI leg)
#   wiring  hooks.json wires the script on UserPromptSubmit
#
# Run: bats hooks/tests/improve-nudge.bats

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$PLUGIN/hooks/improve-nudge.sh"
  NUDGE="This looks like a plan, design or PR about to be acted on: consider /delegation:improve on it first (stress-test, simplify and domain lenses in parallel)."
  unset DELEGATION_IMPROVE_NUDGE
}

payload() { jq -nc --arg p "$1" '{session_id:"s1",hook_event_name:"UserPromptSubmit",prompt:$p}'; }

run_hook() { run bash -c 'printf "%s" "$1" | /bin/bash "$2"' _ "$1" "$HOOK"; }

@test "a plan about to be implemented -> the one nudge line" {
  run_hook "$(payload "Here's my plan for the cache layer. Let's implement it today.")"
  [ "$status" -eq 0 ]
  [ "$output" = "$NUDGE" ]
}

@test "a design proposal with go ahead -> nudge" {
  run_hook "$(payload "Design proposal: move the queue to Redis streams. Go ahead?")"
  [ "$output" = "$NUDGE" ]
}

@test "a GitHub pull-request URL alone -> nudge" {
  run_hook "$(payload "look at https://github.com/acme/api/pull/42")"
  [ "$output" = "$NUDGE" ]
}

@test "merge the PR -> nudge" {
  run_hook "$(payload "the PR is ready, merge it")"
  [ "$output" = "$NUDGE" ]
}

@test "an artifact word with no act word -> silent" {
  run_hook "$(payload "what was the plan for lunch?")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an act word with no artifact word -> silent" {
  run_hook "$(payload "build the docs and deploy to staging")"
  [ -z "$output" ]
}

@test "words that only contain pr or plan are not artifact words -> silent" {
  run_hook "$(payload "start the sprint planning on the planet project, implement nothing")"
  [ -z "$output" ]
}

@test "a prompt that already names /improve -> silent" {
  run_hook "$(payload "/delegation:improve my plan, then implement it")"
  [ -z "$output" ]
  run_hook "$(payload "run /improve on the plan before we build")"
  [ -z "$output" ]
}

@test "a subagent prompt -> silent" {
  run_hook "$(jq -nc '{agent_id:"a1",prompt:"implement the plan"}')"
  [ -z "$output" ]
}

@test "DELEGATION_IMPROVE_NUDGE=0 -> silent" {
  run bash -c 'printf "%s" "$1" | DELEGATION_IMPROVE_NUDGE=0 /bin/bash "$2"' _ "$(payload "implement the plan")" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid JSON or no prompt -> fails open, silent" {
  run_hook "not json {"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook '{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no jq on PATH -> fails open, silent" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in cat tr grep; do ln -s "$(command -v "$t")" "$BATS_TEST_TMPDIR/bin/$t"; done
  run bash -c 'printf "%s" "$1" | PATH="$3" /bin/bash "$2"' _ "$(payload "implement the plan")" "$HOOK" "$BATS_TEST_TMPDIR/bin"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hooks.json wires the script on UserPromptSubmit" {
  cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$PLUGIN/hooks/hooks.json")"
  [[ "$cmd" == *'/hooks/improve-nudge.sh' ]]
  [ -f "$PLUGIN/hooks/improve-nudge.sh" ]
}
