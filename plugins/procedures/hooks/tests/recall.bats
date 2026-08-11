#!/usr/bin/env bats
# Tests for query-records.sh --recall — field-anchored recall over
# mistakes.jsonl (scripts/lib/recall-match.awk).
#
# Run: bats hooks/tests/recall.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"

  # Fixture recall store. Line 2 plants "quokkanoise" ONLY inside non-semantic
  # fields (session id + a URL in refs) — field-anchoring must not match it.
  # Line 4 uses `"key": "value"` spacing (the file mixes both styles).
  cat > "$FIX/mistakes.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","session":"aaa","category":"wrong-action","description":"forgot the quokkafact check before acting","correction":"run the check first","pattern":"skipped-check","severity":"low"}
{"ts":"2026-01-02T00:00:00Z","session":"quokkanoise-123","category":"wrong-action","description":"unrelated record","correction":"do the other thing","refs":"https://example.com/quokkanoise","pattern":"other-thing","severity":"low"}
{"ts":"2026-01-03T00:00:00Z","session":"bbb","category":"wrong-assumption","description":"read a stale pane during the pickup loop and acted on it","correction":"re-read live state","pattern":"stale-pane-read","severity":"medium"}
{"ts": "2026-01-04T00:00:00Z", "session": "ccc", "category": "wrong-action", "description": "another quokkafact miss, spaced-json record", "correction": "same fix", "pattern": "skipped-check", "severity": "low"}
{"ts":"2026-01-05T00:00:00Z","session":"ddd","category":"style-violation","description":"used loopback address in docs","correction":"use the hostname","pattern":"docs-address","severity":"low"}
EOF
}

teardown() { rm -rf "$FIX"; }

@test "recall: matches semantic fields, count line first" {
  run bash "$SCRIPT" --recall quokkafact
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 2 matched" ]
  [[ "$output" == *"skipped-check"* ]]
}

@test "recall: parses spaced-json records (\"key\": \"value\")" {
  run bash "$SCRIPT" --recall "spaced-json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 1 matched" ]
}

@test "recall: term only in session id / URL does not match" {
  run bash "$SCRIPT" --recall quokkanoise
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recall: whole-word — 'loop' does not match 'loopback'" {
  run bash "$SCRIPT" --recall loop
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 1 matched" ]
  [[ "$output" == *"stale-pane-read"* ]]
  [[ "$output" != *"docs-address"* ]]
}

@test "recall: hyphenated term matches as phrase across separators" {
  run bash "$SCRIPT" --recall pickup-loop
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 1 matched" ]
  [[ "$output" == *"stale-pane-read"* ]]
}

@test "recall: phrase does not match its last word alone" {
  # "docs-loop" must not hit the "pickup loop" record via bare "loop".
  run bash "$SCRIPT" --recall docs-loop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recall: --limit caps to most recent with loud count line" {
  run bash "$SCRIPT" --recall "quokkafact pickup-loop" --limit 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 3 matched — showing the 1 most recent (raise --limit for more)" ]
  # most recent = last in file order among matches
  [[ "${lines[1]}" == *"2026-01-04"* ]]
}

@test "recall: phrase cannot match across a field boundary" {
  # pattern ends "check", correction begins "run" — "check-run" must miss.
  run bash "$SCRIPT" --recall check-run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recall: default cap is 20 most recent with loud count line" {
  for i in $(seq 10 34); do
    printf '{"ts":"2026-02-%sT00:00:00Z","session":"x","category":"wrong-action","description":"flooded quokkaflood record %s","correction":"n/a","pattern":"flood","severity":"low"}\n' "$i" "$i" >> "$FIX/mistakes.jsonl"
  done
  run bash "$SCRIPT" --recall quokkaflood
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 25 matched — showing the 20 most recent (raise --limit for more)" ]
  [ "${#lines[@]}" -eq 21 ]
  [[ "${lines[1]}" == *"record 15"* ]]
}

@test "recall: --limit 0 is uncapped" {
  for i in $(seq 10 34); do
    printf '{"ts":"2026-02-%sT00:00:00Z","session":"x","category":"wrong-action","description":"flooded quokkaflood record %s","correction":"n/a","pattern":"flood","severity":"low"}\n' "$i" "$i" >> "$FIX/mistakes.jsonl"
  done
  run bash "$SCRIPT" --recall quokkaflood --limit 0
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 25 matched" ]
  [ "${#lines[@]}" -eq 26 ]
}

@test "recall: QUERY_RECORDS_RECALL_FILE overrides the store path" {
  mv "$FIX/mistakes.jsonl" "$FIX/elsewhere.jsonl"
  QUERY_RECORDS_RECALL_FILE="$FIX/elsewhere.jsonl" run bash "$SCRIPT" --recall quokkafact
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recall: 2 matched" ]
}

@test "recall: cannot combine with --full" {
  run bash "$SCRIPT" --recall x --full
  [ "$status" -eq 2 ]
}

@test "recall: genuine miss is empty stdout exit 0" {
  run bash "$SCRIPT" --recall zzznope
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recall: all-short tokens exit 2, not a silent miss" {
  run bash "$SCRIPT" --recall "a b"
  [ "$status" -eq 2 ]
}

@test "recall: cannot combine with other modes" {
  run bash "$SCRIPT" --recall x --keyword y
  [ "$status" -eq 2 ]
}

@test "recall: missing store is exit 3, not 'no matches'" {
  rm "$FIX/mistakes.jsonl"
  run bash "$SCRIPT" --recall quokkafact
  [ "$status" -eq 3 ]
}
