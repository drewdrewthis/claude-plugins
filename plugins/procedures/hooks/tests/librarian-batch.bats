#!/usr/bin/env bats
# librarian-batch.sh issues one bounded batch of unread transcript lines;
# librarian-advance.sh refuses to move a cursor outside the range the current
# manifest issued. What is enforced: a cursor never passes the end of what was
# issued. That the issued lines were actually read is the librarian prompt's
# rule, not something these scripts can check.
#
# Run: bats hooks/tests/librarian-batch.bats

setup() {
  SCRIPTS="$BATS_TEST_DIRNAME/../../scripts"
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/lb-home.XXXXXX")"
  export PROCEDURES_STATE_DIR="$HOME/state"
  unset CLAUDE_CONFIG_DIR LIBRARIAN_BATCH_BYTES
  PROJ="$HOME/.claude/projects/-proj"
  mkdir -p "$PROJ"
}

teardown() { rm -rf "$HOME"; }

# _transcript <slug> <lines> <days-old> — <lines> user messages of ~100 bytes.
_transcript() {
  local f="$PROJ/$1.jsonl" i
  for i in $(seq 1 "$2"); do
    printf '{"type":"user","message":{"content":"%s msg %03d %s"}}\n' "$1" "$i" "$(printf '%080d' 0)"
  done > "$f"
  touch -t "$(date -d "$3 days ago" +%Y%m%d%H%M)" "$f"
}

_batch() { run bash "$SCRIPTS/librarian-batch.sh"; [ "$status" -eq 0 ]; }
_advance() { run bash "$SCRIPTS/librarian-advance.sh" "$@"; }
_issued() { awk -F'\t' -v s="$1" '$1 == s { print $2 " " $3 }' "$PROCEDURES_STATE_DIR/batch.manifest"; }

@test "batch stays within the byte budget and drains the oldest transcript first" {
  _transcript new 10 1
  _transcript old 10 3
  _transcript mid 10 2
  export LIBRARIAN_BATCH_BYTES=1500
  _batch
  [ "$(cut -f1 "$PROCEDURES_STATE_DIR/batch.manifest" | tr '\n' ' ')" = "old mid " ]
  [ "$(_issued old)" = "0 10" ]
  read -r _ e <<< "$(_issued mid)"
  [ "$e" -lt 10 ]                                                             # mid split at the budget
  [ -z "$(_issued new)" ]                                                     # budget spent before it
  [ "$(wc -c < "$PROCEDURES_STATE_DIR/batch.txt")" -le 1500 ]
  grep -q '^\[L1\] user: old msg 001' "$PROCEDURES_STATE_DIR/batch.txt"
}

@test "a transcript bigger than the budget splits across two batches with no gap or overlap" {
  _transcript big 20 1
  export LIBRARIAN_BATCH_BYTES=1000
  _batch
  read -r s1 e1 <<< "$(_issued big)"
  [ "$s1" -eq 0 ]
  [ "$e1" -gt 0 ]
  [ "$e1" -lt 20 ]
  grep -q "^\[L$e1\] " "$PROCEDURES_STATE_DIR/batch.txt"
  ! grep -q "^\[L$((e1 + 1))\] " "$PROCEDURES_STATE_DIR/batch.txt" || false
  _advance big "$e1"
  [ "$status" -eq 0 ]
  _batch
  read -r s2 e2 <<< "$(_issued big)"
  [ "$s2" -eq "$e1" ]                                                         # resumes exactly after
  [ "$e2" -gt "$s2" ]
  grep -q "^\[L$((e1 + 1))\] " "$PROCEDURES_STATE_DIR/batch.txt"
  ! grep -q "^\[L$e1\] " "$PROCEDURES_STATE_DIR/batch.txt" || false
}

@test "advance refuses to move a cursor past the issued end" {
  _transcript t 20 1
  export LIBRARIAN_BATCH_BYTES=1000
  _batch
  read -r _ e <<< "$(_issued t)"
  _advance t 20
  [ "$status" -ne 0 ]
  [[ "$output" == *"past the issued end $e"* ]]
  [ ! -f "$PROCEDURES_STATE_DIR/cursors/t.line" ]
  _advance t "$e"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROCEDURES_STATE_DIR/cursors/t.line")" = "$e" ]
}

@test "advance with no manifest, or for a slug not issued, refuses" {
  _transcript t 3 1
  _advance t 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no batch manifest"* ]]
  _batch
  _advance other 1
  [ "$status" -ne 0 ]
  [ ! -f "$PROCEDURES_STATE_DIR/cursors/t.line" ]
}

@test "a truncated transcript resets its cursor to 0; any other backward move refuses" {
  _transcript t 5 1
  mkdir -p "$PROCEDURES_STATE_DIR/cursors"
  echo 50 > "$PROCEDURES_STATE_DIR/cursors/t.line"
  _batch
  [ "$(_issued t)" = "0 5" ]
  grep -q '^\[L1\] ' "$PROCEDURES_STATE_DIR/batch.txt"
  _advance t 5
  [ "$status" -eq 0 ]
  [ "$(cat "$PROCEDURES_STATE_DIR/cursors/t.line")" = "5" ]
  _transcript u 5 1
  echo 3 > "$PROCEDURES_STATE_DIR/cursors/u.line"
  _batch
  [ "$(_issued u)" = "3 5" ]
  _advance u 2
  [ "$status" -ne 0 ]
  [ "$(cat "$PROCEDURES_STATE_DIR/cursors/u.line")" = "3" ]
}

@test "transcripts older than 7 days and fully read ones are skipped" {
  _transcript stale 5 8
  _transcript done 5 1
  mkdir -p "$PROCEDURES_STATE_DIR/cursors"
  echo 5 > "$PROCEDURES_STATE_DIR/cursors/done.line"
  _batch
  [ ! -s "$PROCEDURES_STATE_DIR/batch.manifest" ]
  [ ! -s "$PROCEDURES_STATE_DIR/batch.txt" ]
}

@test "unparseable and text-free lines are skipped but still issued as read" {
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' 'not json' '{"type":"system"}' > "$PROJ/m.jsonl"
  _batch
  [ "$(_issued m)" = "0 3" ]
  [ "$(grep -c '^\[L' "$PROCEDURES_STATE_DIR/batch.txt")" -eq 1 ]
}

@test "lines jq cannot distill (in the middle and last) keep line numbers and the full range" {
  printf '%s\n' \
    '{"type":"user","message":{"content":"one"}}' \
    '{"type":"user","message":"str"}' \
    '{"type":"user","message":{"content":["bare",{"type":"text","text":{"x":1}}]}}' \
    '{"type":"user","message":{"content":"four"}}' \
    '{"type":"assistant","message":"str"}' > "$PROJ/m.jsonl"
  _transcript later 2 0
  _batch
  [ "$(_issued m)" = "0 5" ]                                                  # bad last line does not stall
  [ "$(_issued later)" = "0 2" ]                                              # nor block younger transcripts
  grep -q '^\[L1\] user: one$' "$PROCEDURES_STATE_DIR/batch.txt"
  grep -q '^\[L3\] user: bare$' "$PROCEDURES_STATE_DIR/batch.txt"
  grep -q '^\[L4\] user: four$' "$PROCEDURES_STATE_DIR/batch.txt"
  [ "$(grep -c '^\[L' "$PROCEDURES_STATE_DIR/batch.txt")" -eq 5 ]              # m: L1 L3 L4, later: L1 L2
  [ "$(grep -c '^\[L5\]' "$PROCEDURES_STATE_DIR/batch.txt")" -eq 0 ]
}

@test "a failed batch leaves no manifest behind, so nothing stale can be advanced" {
  _transcript t 3 1
  _batch
  [ "$(_issued t)" = "0 3" ]
  LIBRARIAN_BATCH_BYTES=nope run bash "$SCRIPTS/librarian-batch.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$PROCEDURES_STATE_DIR/batch.manifest" ]
  _advance t 3
  [ "$status" -ne 0 ]
  [ ! -f "$PROCEDURES_STATE_DIR/cursors/t.line" ]
}
