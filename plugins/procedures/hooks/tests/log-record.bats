#!/usr/bin/env bats
# Tests for scripts/log-record.sh `mistake` — the --source flag (claude#41):
# it sets the session, and a second row for the same session and an
# overlapping or touching line range is refused, in any store root.
# Run: bats hooks/tests/log-record.bats

setup() {
  LOG="$BATS_TEST_DIRNAME/../../scripts/log-record.sh"
  D="$(mktemp -d "${BATS_TMPDIR:-/tmp}/lr.XXXXXX")"
  export HOME="$D/home"; mkdir -p "$HOME"
  mkdir -p "$D/a" "$D/b"
  export MISTAKES_JSONL="$D/a/mistakes.jsonl"
  export CODEX_STORE_ROOTS="$D/a:$D/b"
  export CODEX_ROOT="$D/a"
  unset MISTAKES_NO_FLOCK
}

# _m [flags…] — one mistake call; extra flags are appended.
_m() {
  run bash "$LOG" mistake --category c --trigger t --description d \
    --correction x --severity low "$@"
}
_rows() { wc -l < "$MISTAKES_JSONL" | tr -d ' '; }

@test "--source fills the session and stores the source" {
  _m --source "s1:653-670"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.session,.source]|join(" ")' "$MISTAKES_JSONL")" = "s1 s1:653-670" ]
}

@test "an explicit --session wins over the session in --source" {
  _m --source "s1:653-670" --session X
  [ "$(jq -r .session "$MISTAKES_JSONL")" = "X" ]
}

@test "a --source of the wrong shape exits non-zero" {
  _m --source "s0:1-2"                      # control: a well-formed value is accepted
  [ "$status" -eq 0 ]
  for bad in abc "s1:5-3" ":1-2" "s1:a-b" "s1:5"; do
    _m --source "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "a --source of the wrong shape appends nothing" {
  _m --source "s0:1-2"
  _m --source "s1:5-3"
  [ "$(_rows)" -eq 1 ]
}

@test "with neither flag the row is appended with an empty session" {
  _m
  [ "$status" -eq 0 ]
  [ "$(jq -r .session "$MISTAKES_JSONL")" = "" ]
}

@test "with neither flag stderr says no session" {
  _m
  [[ "$output" == *"no session"* ]]
}

@test "the same session and range again appends nothing and exits 0" {
  _m --source "s1:653-670"
  _m --source "s1:653-670"
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 1 ]
}

@test "the duplicate note names the session, the range and the matched row's ts" {
  _m --source "s1:653-670" --ts 2026-01-02T03:04:05Z
  _m --source "s1:653-670"
  [[ "$output" == *duplicate* && "$output" == *s1* && "$output" == *653-670* && "$output" == *2026-01-02T03:04:05Z* ]]
}

@test "an overlapping range in the same session is a duplicate" {
  _m --source "s1:653-670"
  _m --source "s1:660-675"
  [ "$(_rows)" -eq 1 ]
}

@test "a range touching at one line in the same session is a duplicate" {
  _m --source "s1:653-670"
  _m --source "s1:670-675"
  [ "$(_rows)" -eq 1 ]
}

@test "the same range in another session appends" {
  _m --source "s1:653-670"
  _m --source "s2:653-670"
  [ "$(_rows)" -eq 2 ]
}

@test "a range that does not touch, in the same session, appends" {
  _m --source "s1:653-670"
  _m --source "s1:672-680"
  [ "$(_rows)" -eq 2 ]
}

@test "the same range with another category is still a duplicate" {
  _m --source "s1:653-670"
  run bash "$LOG" mistake --category other --trigger t --description d \
    --correction x --severity low --source "s1:653-670"
  [ "$(_rows)" -eq 1 ]
}

@test "a match in another store root's mistakes.jsonl is a duplicate" {
  jq -nc '{ts:"2026-01-02T03:04:05Z",session:"s1",source:"s1:653-670"}' > "$D/b/mistakes.jsonl"
  _m --source "s1:660-675"
  [[ "$output" == *duplicate* ]]
  [ ! -s "$MISTAKES_JSONL" ]
}

@test "rows with no source key never match" {
  jq -nc '{ts:"2026-01-02T03:04:05Z",session:"s1"}' > "$MISTAKES_JSONL"
  _m --source "s1:653-670"
  [ "$(_rows)" -eq 2 ]
}

@test "a refused duplicate leaves the earlier bytes unchanged" {
  _m --source "s1:653-670"
  cp "$MISTAKES_JSONL" "$D/before"
  _m --source "s1:653-670"
  cmp "$D/before" "$MISTAKES_JSONL"
}

@test "an accepted append leaves the earlier bytes unchanged" {
  _m --source "s1:653-670"
  cp "$MISTAKES_JSONL" "$D/before"
  _m --source "s2:1-2"
  [ "$(head -c "$(wc -c < "$D/before")" "$MISTAKES_JSONL" | cmp - "$D/before"; echo $?)" = 0 ]
}

@test "ten parallel identical calls leave one new row" {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$LOG" mistake --category c --trigger t --description d --correction x \
      --severity low --source "s1:653-670" >/dev/null 2>&1 &
  done
  wait
  [ "$(_rows)" -eq 1 ]
}

@test "after ten parallel calls every line parses as JSON" {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$LOG" mistake --category c --trigger t --description d --correction x \
      --severity low --source "s1:653-670" >/dev/null 2>&1 &
  done
  wait
  jq -e . "$MISTAKES_JSONL" >/dev/null
}
