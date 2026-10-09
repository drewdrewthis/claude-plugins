#!/usr/bin/env bats
# Tests for hooks/decision-ask-guard.sh - PreToolUse deny of a Discord reply that asks
# the owner to decide items not marked one-way-door/values-laden with a recommendation.
#
# Coverage map:
#   deny    unmarked/partly-marked/negated-marker lists, single asks, ask phrasings
#           (should we, can you approve, ok to, your pick, thoughts?, ...)
#   allow   status reports, past-tense "your call/decision/approval", fully marked
#           lists, status lists before/after a marked ask, "let me know if you have..."
#   score   multi-block asks (second/third ask after a blank line), a marker without a
#           recommendation, a question in the list header counted as an item
#   strip   "?" in a URL, fenced code or inline code is not an ask (allow), and each strip
#           arm is pinned alone; inline code is kept (minus "?") only when it holds a
#           marker or rec, else deleted (quoted prompts/labels are not asks); an unmarked ask
#           ending in a URL, angle-bracket URL, markdown link, parentheses, or "ok to <URL>",
#           or beside code, is (deny); a status sentence ending in a URL with a query is (allow)
#   later   the URL footer, fenced code footer and ternary tests pin the later-block rule
#           together with the strip; a prose-question footer is not an ask, a real later
#           ask (also one ending in a URL) is
#   dots    an ask tail may cross a dot inside a token (config.yml, 0.3.0); a dot continues
#           the ask only before a word character, so a quote/bracket after it ends the sentence
#   other   non-reply tool or non-PreToolUse event carrying ask text, empty text ->
#           empty output, exit 0; word-boundary allows (took to, American, google creds)
#   open    invalid JSON, no jq, or no python3 on PATH -> fails open (empty stdout,
#           exit 0; the tool miss is logged to stderr); a scorer crash and a long
#           pathological text (denied within the 5s hook timeout) are covered too
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

@test "Bash tool carrying ask text -> empty, exit 0" {
  run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"text":"Should we merge 8501?"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-PreToolUse event carrying ask text -> empty, exit 0" {
  run_hook '{"hook_event_name":"PostToolUse","tool_name":"mcp__plugin_discord_discord__reply","tool_input":{"text":"Should we merge 8501?"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "markers without recommendations -> deny" {
  assert_denied "Decisions for you: 1) merge 8501? one-way-door. 2) stop slot? values-laden."
}

@test "header question with fully marked bullets -> deny" {
  assert_denied $'Should we do these?\n- a one-way-door, recommend yes\n- b values-laden, recommend yes'
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
  grep -q "unparseable input, failing open" "$BATS_TEST_TMPDIR/err"
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

@test "second ask after a blank line: unmarked bullets -> deny" {
  assert_denied $'Decisions for you:\n- drop table? one-way-door, recommend keep.\n\nAnd these:\n- merge 8501?\n- stop slot?'
}

@test "second ask after a blank line: prose question -> deny" {
  assert_denied $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nAlso, should I restart the technician and delete the branch?'
}

@test "third ask after blank lines -> deny" {
  assert_denied $'Should I merge 8501? one-way-door, I recommend merge.\n\nShould I stop the devtool slot?\n\nShould I delete the worktree?'
}

@test "marked ask + footer URL with a query ? -> empty" {
  assert_allowed $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nPR: https://github.com/o/r/pull/5?diff=split'
}

@test "unmarked ask ending in a URL -> deny" {
  assert_denied "Should I merge https://example.com/pull/8501?"
}

@test "unmarked ask ending in a parenthesised URL -> deny" {
  assert_denied "Should I merge (https://example.com/pull/8501)?"
}

@test "unmarked ask ending in an angle-bracket URL -> deny" {
  assert_denied "Should I merge <https://github.com/o/r/pull/5>?"
}

@test "unmarked ask with the ? inside the angle brackets -> deny" {
  assert_denied "Should I merge <https://x.io/5?>"
}

@test "unmarked ask ending in a markdown link -> deny" {
  assert_denied "Should I merge [PR 5](https://github.com/o/r/pull/5)?"
}

@test "unmarked ask ending in a bare URL after can-you-approve -> deny" {
  assert_denied "Can you approve https://github.com/o/r/pull/5?"
}

@test "second ask after a blank line ending in a URL -> deny" {
  assert_denied $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nShould I also merge https://github.com/o/r/pull/9?'
}

@test "second ask list after a blank line ending in URLs -> deny" {
  assert_denied $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nAnd these:\n- merge https://github.com/o/r/pull/9?\n- close https://github.com/o/r/pull/10?'
}

@test "ok-to ask whose object is a URL -> deny" {
  assert_denied "Ok to https://example.com/pull/8501?"
}

@test "status sentence ending in a URL with a query -> empty" {
  assert_allowed "Merged. See https://github.com/o/r/pull/5?diff=split."
}

@test "marked ask + fenced code with a ? in a URL -> empty" {
  assert_allowed $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\n```\ncurl \'https://api.x/y?a=1&b=2\'\n```'
}

@test "marked ask + inline code with a ternary ? -> empty" {
  assert_allowed $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nFix was `x = a ? b : c`.'
}

@test "marker and rec in inline code -> empty" {
  assert_allowed 'Decisions for you: 1) merge 8501? `one-way-door`, I recommend merge.'
  assert_allowed 'Should I drop the prod table? `one-way-door` - `rec: no`'
}

@test "fence arm alone: ask phrase in a fenced block -> empty" {
  assert_allowed $'Ran:\n```\nshould we revert?\n```\ndone.'
}

@test "URL arm alone: ask phrase before a URL query ? -> empty" {
  assert_allowed 'Merged; ok to ignore https://x.io/pull/5?diff=split for now.'
}

@test "ask phrase only inside inline code, no ask -> empty" {
  assert_allowed 'Ran `grep -r should we revert?` and found nothing.'
}

@test "marked ask + prose-question footer -> empty" {
  assert_allowed $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nWhy did CI fail? A flaky test; I reran it and it is green.'
}

@test "marked ask + later real ask containing a URL -> deny" {
  assert_denied $'Decision for you: drop the prod table? one-way-door, I recommend keep.\n\nAnd merge https://x.io/a?b=1 too? Should I?'
}

@test "quoted prompt in inline code -> empty" {
  assert_allowed 'The installer stopped at `Proceed? (y/n)`; I piped `yes` into it and it finished.'
}

@test "always-phrase quoted in inline code -> empty" {
  assert_allowed 'I renamed the label `needs your approval` to `pending-review` in all 4 workflows.'
}

@test "ask about a file name in inline code -> deny" {
  assert_denied 'Should I delete `config.yml`?'
}

@test "unmarked ask next to inline code -> deny" {
  assert_denied 'Should I run `rm -rf build`?'
}

@test "ask with a dotted file name -> deny" {
  assert_denied "Should I delete config.yml?"
}

@test "ask with a version number -> deny" {
  assert_denied "Should I bump the plugin to 0.3.0?"
}

@test "sentence end before a closing quote, then a question -> empty" {
  assert_allowed 'The log line was "ok to merge." Did it merge? Yes, at 14:02.'
}

@test "sentence end before a closing bracket, then a question -> empty" {
  assert_allowed "Merged per your approval (see notes.) Anything broken? No, CI is green."
}

@test "ask phrase, sentence end, then a bare Why? -> empty" {
  assert_allowed "Should I merge. It is done. Why?"
}

@test "long pathological text is denied within 5s of CPU" {
  payload="$(python3 -c 'import json; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"mcp__plugin_discord_discord__reply","tool_input":{"chat_id":"1","text":"ok to a "*12000+"\n- Should I merge PR 5?"}}))')"
  # python3 enforces the limit: GNU timeout is absent on stock macOS.
  # CPU time, not wall time: wall clock inflates under machine load (flaky),
  # while a quadratic regex burns CPU regardless. The rlimit is inherited by
  # the scorer; the 60s wall timeout is only a backstop against a hang.
  out="$(printf '%s' "$payload" | python3 -c 'import os,resource,signal,subprocess,sys
p = subprocess.Popen(["/bin/bash", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True, preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CPU, (5, 5)))
try:
    sys.stdout.write(p.communicate(sys.stdin.read(), timeout=60)[0])
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)' "$HOOK")"
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny ]
}

@test "python3 scorer fails -> fails open: exit 0, no stdout, stderr names it" {
  err="$BATS_TEST_TMPDIR/err"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v jq)" "$bin/jq"
  printf '#!/bin/sh\nexit 1\n' > "$bin/python3"
  chmod +x "$bin/python3"
  out="$(printf '%s' "$(reply_json "Should we merge 8501?")" | PATH="$bin" /bin/bash "$HOOK" 2>"$err")"
  rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  grep -q "decision-ask-guard:.*failing open" "$err"
}

@test "took-to word, no ask -> empty" {
  assert_allowed "I took to fixing the flake first; any questions?"
}

@test "American word, no ask -> empty" {
  assert_allowed "Merged 8501. The American we hired starts Monday, right?"
}

@test "did not need your google creds -> empty" {
  assert_allowed "I did not need your google creds after all."
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
