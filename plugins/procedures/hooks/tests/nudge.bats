#!/usr/bin/env bats
# nudge.sh prints the skills reminder and, after it, record hints from
# scripts/record-hints.sh. These tests pin: a prompt sharing words with a
# record lists that record; a prompt sharing nothing adds no hint lines; one
# shared word is not enough; the hint cap holds; and every failure of the hint
# lookup leaves the reminder line alone and exits 0.
#
# Run: bats hooks/tests/nudge.bats

bats_require_minimum_version 1.5.0
load helpers/common

REMINDER="Available: /what-do-i-know (knowledge retrieval), /adherence-check (finished-work review)."

setup() {
  clear_gate_switches
  HOOK="$BATS_TEST_DIRNAME/../nudge.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GATE_ESCAPE_LOG="$BATS_TEST_TMPDIR/gate-escape.jsonl"
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/records/solutions" "$ROOT/records/decisions"
  export CODEX_STORE_ROOTS="$ROOT"
  unset CODEX_RECORDS_DIR RECORD_HINTS_MAX RECORD_HINTS_MIN_TERMS RECORD_HINTS_TIMEOUT

  cat > "$ROOT/records/solutions/poller-conflict.md" <<'EOF'
---
id: sol.telegram-poller-conflict
kind: solution
date: 2026-08-01
keywords: [telegram, poller, "409"]
links: {}
status: active
description: Two telegram pollers on one bot token return 409 conflicts; kill the orphan.
---
# Body
EOF
  cat > "$ROOT/records/decisions/release-titles.md" <<'EOF'
---
id: dec.release-titles
kind: decision
date: 2026-08-02
keywords: [release, versioning]
links: {}
status: active
description: The squash title drives the release bump.
---
# Body
EOF
}

prompt_json() { jq -nc --arg p "$1" '{session_id:"s1", hook_event_name:"UserPromptSubmit", prompt:$p}'; }

@test "a prompt sharing words with a record lists it after the reminder" {
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'the telegram poller keeps getting 409 conflicts')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REMINDER" ]
  [[ "${lines[1]}" == "Related records — open one if it applies"* ]]
  [ "${lines[2]}" = "  sol.telegram-poller-conflict — Two telegram pollers on one bot token return 409 conflicts; kill the orphan." ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "a prompt sharing no words with any record prints only the reminder" {
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'please summarise yesterday standup notes')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "one shared word is not enough for a hint" {
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'what is the weather in telegram land')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "stopwords and short words never count as shared words" {
  # Each prompt shares "telegram" plus one word the record also holds; were
  # "409" (3 chars) or "should" (a stopword) counted, it would be 2 words.
  printf -- '---\nid: sol.should-telegram\ndescription: you should restart telegram\n---\n' \
    > "$ROOT/records/solutions/should.md"
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'telegram 409')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'telegram should')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "hints are capped at RECORD_HINTS_MAX records" {
  for i in 1 2 3 4 5 6 7; do
    printf -- '---\nid: sol.cap-%s\nkeywords: [alpha, gamma]\ndescription: alpha gamma record %s\n---\n' "$i" "$i" \
      > "$ROOT/records/solutions/cap-$i.md"
  done
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'alpha gamma')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^  sol\.cap-')" -eq 5 ]
  RECORD_HINTS_MAX=2 run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'alpha gamma')"
  [ "$(printf '%s\n' "$output" | grep -c '^  sol\.cap-')" -eq 2 ]
}

@test "a missing knowledge root fails open: reminder only, exit 0" {
  export CODEX_STORE_ROOTS="$BATS_TEST_TMPDIR/does-not-exist"
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'the telegram poller keeps getting 409 conflicts')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "an unreadable record file fails open: the other records still match, exit 0" {
  skip_if_root
  chmod 000 "$ROOT/records/decisions/release-titles.md"
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'the telegram poller keeps getting 409 conflicts')"
  chmod 644 "$ROOT/records/decisions/release-titles.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REMINDER" ]
  [ "${lines[2]}" = "  sol.telegram-poller-conflict — Two telegram pollers on one bot token return 409 conflicts; kill the orphan." ]
}

@test "the hint block never exceeds a header plus RECORD_HINTS_MAX lines" {
  for i in 1 2 3 4 5 6 7; do
    printf -- '---\nid: sol.cap-%s\nkeywords: [alpha, gamma]\ndescription: alpha gamma record %s\n---\n' "$i" "$i" \
      > "$ROOT/records/solutions/cap-$i.md"
  done
  run --separate-stderr bash "$HOOK" <<<"$(prompt_json 'alpha gamma')"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]   # reminder + header + 5 hints
}

@test "a broken hint script fails open: reminder only, exit 0" {
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN/hooks" "$PLUGIN/scripts"
  cp -R "$BATS_TEST_DIRNAME/../nudge.sh" "$BATS_TEST_DIRNAME/../lib" "$PLUGIN/hooks/"
  printf 'echo partial-output\nexit 3\n' > "$PLUGIN/scripts/record-hints.sh"
  run --separate-stderr bash "$PLUGIN/hooks/nudge.sh" <<<"$(prompt_json 'the telegram poller keeps getting 409 conflicts')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "a hint lookup slower than RECORD_HINTS_TIMEOUT is dropped: reminder only, exit 0" {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || skip "no timeout/gtimeout"
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN/hooks" "$PLUGIN/scripts"
  cp -R "$BATS_TEST_DIRNAME/../nudge.sh" "$BATS_TEST_DIRNAME/../lib" "$PLUGIN/hooks/"
  printf 'sleep 5\necho late-hint\n' > "$PLUGIN/scripts/record-hints.sh"
  RECORD_HINTS_TIMEOUT=1 run --separate-stderr bash "$PLUGIN/hooks/nudge.sh" <<<"$(prompt_json 'anything at all')"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMINDER" ]
}

@test "a subagent prompt gets neither the reminder nor hints" {
  run --separate-stderr bash "$HOOK" <<<"$(jq -nc '{session_id:"s1", agent_id:"a1", prompt:"telegram poller 409 conflicts"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
