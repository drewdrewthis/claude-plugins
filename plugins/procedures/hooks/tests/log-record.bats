#!/usr/bin/env bats
# Tests for scripts/log-record.sh's path-forming argument checks. The headless
# librarian may call it with open arguments taken from untrusted transcripts,
# so a slug or date that could leave the records dir must be refused.
# Run: bats hooks/tests/log-record.bats

setup() {
  WRITER="$BATS_TEST_DIRNAME/../../scripts/log-record.sh"
  FIX="$(mktemp -d)"
  export HOME="$FIX/home"; mkdir -p "$HOME/.claude"
  export CODEX_ROOT="$FIX/root"; mkdir -p "$CODEX_ROOT/records"
  export MISTAKES_JSONL="$CODEX_ROOT/mistakes.jsonl"; : > "$MISTAKES_JSONL"
  unset DECISIONS_DIR SOLUTIONS_DIR FAILURE_MODES_DIR
}
teardown() { rm -rf "$FIX"; }

# _no_stray — nothing was written anywhere but the (still empty) records tree.
_no_stray() {
  [ -z "$(find "$CODEX_ROOT/records" -type f)" ]
  [ ! -e "$HOME/.claude/CLAUDE.md" ]
  [ -z "$(find "$FIX" -name '*.md' -newer "$MISTAKES_JSONL")" ]
}

@test "decision: a traversal slug is refused and nothing is written" {
  run bash "$WRITER" decision --slug "x/../../../../home/.claude/CLAUDE" --date 2026-10-09
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --slug"* ]]
  _no_stray
}

# _extra <kind> — the flags failure-mode needs that the others reject.
_extra() { [ "$1" = failure-mode ] && printf '%s\n' --rule r --skip-gate; true; }

@test "decision / solution / failure-mode: '/', '..' and other characters are refused in --slug" {
  local kind slug
  for kind in decision solution failure-mode; do
    for slug in "a/b" ".." "a..b" "a b" 'a$b' "a;b"; do
      run bash "$WRITER" "$kind" --slug "$slug" --date 2026-10-09 $(_extra "$kind")
      [ "$status" -ne 0 ]
      [[ "$output" == *"invalid --slug"* ]]
    done
  done
  _no_stray
}

@test "decision / solution / failure-mode: a slug naming an auto-loaded memory file is refused, any case" {
  local kind slug
  for kind in decision solution failure-mode; do
    for slug in CLAUDE claude agents AGENTS CLAUDE.local claude.LOCAL; do
      run bash "$WRITER" "$kind" --slug "$slug" --date 2026-10-09 $(_extra "$kind")
      [ "$status" -ne 0 ]
      [[ "$output" == *"invalid --slug"* ]]
      [[ "$output" == *"auto-loads as instructions"* ]]
    done
  done
  [ ! -e "$CODEX_ROOT/records/failure-modes/CLAUDE.md" ]
  _no_stray
}

@test "decision / solution / failure-mode: non-ASCII and dot/dash-edged slugs are refused (LC_ALL=C)" {
  local kind slug
  for kind in decision solution failure-mode; do
    for slug in "é" "café" "ｆｕｌｌ" "." "-x" "--force" ".x" ".hidden" "x."; do
      LC_ALL=en_US.UTF-8 run bash "$WRITER" "$kind" --slug "$slug" --date 2026-10-09 $(_extra "$kind")
      [ "$status" -ne 0 ]
      [[ "$output" == *"invalid --slug"* ]]
    done
  done
  _no_stray
}

@test "decision / solution / failure-mode: a --date that is not YYYY-MM-DD is refused" {
  local kind date
  for kind in decision solution failure-mode; do
    for date in "../../x" "2026-10-9" "2026/10/09" "20261009" "2026-10-09x" "x"; do
      run bash "$WRITER" "$kind" --slug ok --date "$date" $(_extra "$kind")
      [ "$status" -ne 0 ]
      [[ "$output" == *"invalid --date"* ]]
    done
  done
  _no_stray
}

@test "a valid slug and date still write under the records dir" {
  run bash "$WRITER" decision --slug ok.slug_1-x --date 2026-10-09
  [ "$status" -eq 0 ]
  [ -f "$CODEX_ROOT/records/decisions/2026-10-09-ok.slug_1-x.md" ]
  run bash "$WRITER" solution --slug ok --date 2026-10-09
  [ "$status" -eq 0 ]
  [ -f "$CODEX_ROOT/records/solutions/2026-10-09-ok.md" ]
  run bash "$WRITER" failure-mode --slug ok --rule r --skip-gate
  [ "$status" -eq 0 ]
  [ -f "$CODEX_ROOT/records/failure-modes/ok.md" ]
}

@test "a record path that is a symlink out of the records dir is refused (--force too)" {
  mkdir -p "$CODEX_ROOT/records/decisions"
  : > "$FIX/outside.md"
  ln -s "$FIX/outside.md" "$CODEX_ROOT/records/decisions/2026-10-09-link.md"
  run bash "$WRITER" decision --slug link --date 2026-10-09 --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -s "$FIX/outside.md" ]
}

# The headless librarian pins CODEX_ROOT per call, but an `export X=... &&
# <pinned call>` allowed by some other settings source could still set these.
# With CODEX_ROOT set, each must resolve to the path CODEX_ROOT implies.

@test "CODEX_ROOT set: a target-dir override that leaves the root is refused, nothing written" {
  local kind var
  mkdir -p "$HOME/.claude/agents"
  for kind in decision solution failure-mode; do
    for var in DECISIONS_DIR SOLUTIONS_DIR FAILURE_MODES_DIR; do
      for dest in "$HOME/.claude/agents" "$CODEX_ROOT/records/decisions/../../.claude" \
                  "$CODEX_ROOT/records" "$CODEX_ROOT/records/decisions/sub" "relative/dir"; do
        run env "$var=$dest" bash "$WRITER" "$kind" --slug x --date 2026-10-09 $(_extra "$kind")
        [ "$status" -ne 0 ]
        [[ "$output" == *"refusing $var="* ]]
      done
    done
  done
  [ -z "$(find "$HOME/.claude/agents" -type f)" ]
  [ ! -e "$CODEX_ROOT/.claude" ]
  _no_stray
}

@test "CODEX_ROOT set: MISTAKES_JSONL outside \$CODEX_ROOT/mistakes.jsonl is refused, nothing appended" {
  local dest
  for dest in "$HOME/.claude/mistakes.jsonl" "$HOME/.claude/agents/x.md" "$CODEX_ROOT/records/m.jsonl"; do
    run env MISTAKES_JSONL="$dest" bash "$WRITER" mistake --category c --description d \
      --correction x --severity low --trigger t
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing MISTAKES_JSONL="* ]]
    [ ! -e "$dest" ]
  done
  [ ! -s "$CODEX_ROOT/mistakes.jsonl" ]
  # Also refused for a kind that never reads it: the check runs before any write.
  run env MISTAKES_JSONL="$HOME/.claude/mistakes.jsonl" bash "$WRITER" decision --slug x --date 2026-10-09
  [ "$status" -ne 0 ]
  _no_stray
}

@test "CODEX_ROOT set: CODEX_RECORDS_DIR other than the root's own records dir is refused" {
  local d
  for d in "../.claude/agents" "/tmp" "references" "records/decisions"; do
    run env CODEX_RECORDS_DIR="$d" bash "$WRITER" decision --slug x --date 2026-10-09
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing CODEX_RECORDS_DIR="* ]]
  done
  _no_stray
}

@test "CODEX_ROOT set: overrides equal to the derived paths (via a symlinked root too) still work" {
  run env DECISIONS_DIR="$CODEX_ROOT/records/decisions" CODEX_RECORDS_DIR=records \
    bash "$WRITER" decision --slug ok --date 2026-10-09
  [ "$status" -eq 0 ]
  [ -f "$CODEX_ROOT/records/decisions/2026-10-09-ok.md" ]
  ln -s "$CODEX_ROOT" "$FIX/root-link"
  run env CODEX_ROOT="$FIX/root-link" MISTAKES_JSONL="$CODEX_ROOT/mistakes.jsonl" \
    bash "$WRITER" mistake --category c --description d --correction x --severity low --trigger t
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CODEX_ROOT/mistakes.jsonl")" -eq 1 ]
}

@test "CODEX_ROOT set, MISTAKES_JSONL unset: the mistake goes to \$CODEX_ROOT/mistakes.jsonl" {
  unset MISTAKES_JSONL
  run bash "$WRITER" mistake --category c --description d --correction x --severity low --trigger t
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CODEX_ROOT/mistakes.jsonl")" -eq 1 ]
  [ ! -e "$HOME/.claude/mistakes.jsonl" ]
}

@test "CODEX_ROOT unset: the overrides keep their old behaviour" {
  unset CODEX_ROOT
  run env DECISIONS_DIR="$FIX/elsewhere" MISTAKES_JSONL="$FIX/m.jsonl" \
    bash "$WRITER" decision --slug ok --date 2026-10-09
  [ "$status" -eq 0 ]
  [ -f "$FIX/elsewhere/2026-10-09-ok.md" ]
}

@test "a mistakes.jsonl that is a symlink is refused" {
  rm -f "$MISTAKES_JSONL"; : > "$FIX/outside.jsonl"
  ln -s "$FIX/outside.jsonl" "$MISTAKES_JSONL"
  run bash "$WRITER" mistake --category c --description d --correction x --severity low --trigger t
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -s "$FIX/outside.jsonl" ]
}

# ---- --source flag (claude#41): sets the session; a second row for the same
# session and an overlapping or touching line range is refused, in any store root.

# _src_env — re-point the fixture at two store roots under $FIX/src. The records
# dirs stay under CODEX_ROOT, so the MISTAKES_JSONL pin is obeyed.
_src_env() {
  LOG="$WRITER"
  D="$FIX/src"
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
  _src_env
  _m --source "s1:653-670"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.session,.source]|join(" ")' "$MISTAKES_JSONL")" = "s1 s1:653-670" ]
}

@test "an explicit --session wins over the session in --source" {
  _src_env
  _m --source "s1:653-670" --session X
  [ "$(jq -r .session "$MISTAKES_JSONL")" = "X" ]
}

@test "a --source of the wrong shape exits non-zero and appends nothing" {
  _src_env
  _m --source "s0:1-2"                      # control: a well-formed value is accepted
  [ "$status" -eq 0 ]
  for bad in abc "s1:5-3" ":1-2" "s1:a-b" "s1:5" "a b:1-2" $'a\nb:1-2' "s1:1-99999999999999999999"; do
    _m --source "$bad"
    [ "$status" -ne 0 ]
  done
  [ "$(_rows)" -eq 1 ]
}

@test "with neither flag the row is appended with an empty session" {
  _src_env
  _m
  [ "$status" -eq 0 ]
  [ "$(jq -r .session "$MISTAKES_JSONL")" = "" ]
}

@test "with neither flag stderr says no session" {
  _src_env
  _m
  [[ "$output" == *"no session"* ]]
}

@test "the same session and range again appends nothing and exits 0" {
  _src_env
  _m --source "s1:653-670"
  _m --source "s1:653-670"
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 1 ]
}

@test "the duplicate note names the source, the range and the matched row's ts" {
  _src_env
  _m --source "s1:653-670" --ts 2026-01-02T03:04:05Z
  _m --source "s1:653-670"
  [[ "$output" == *duplicate* && "$output" == *s1* && "$output" == *653-670* && "$output" == *2026-01-02T03:04:05Z* ]]
}

@test "two overlapping rows give a one-line duplicate note naming the first row's ts" {
  _src_env
  jq -nc '{ts:"T1",source:"s2:5-9"}' > "$MISTAKES_JSONL"
  jq -nc '{ts:"T2",source:"s2:10-12"}' >> "$MISTAKES_JSONL"
  _m --source "s2:9-10"
  [ "$status" -eq 0 ]
  [ "$(grep -c duplicate <<<"$output")" -eq 1 ]
  [[ "$output" == *"row ts T1)"* && "$output" != *T2* ]]
  [ "$(_rows)" -eq 2 ]
}

@test "a covering row with an empty or missing ts still counts as a duplicate" {
  _src_env
  jq -nc '{ts:"",source:"s1:653-670"}' > "$MISTAKES_JSONL"
  _m --source "s1:660-675"
  [[ "$output" == *duplicate* ]]
  jq -nc '{source:"s2:1-5"}' > "$MISTAKES_JSONL"
  _m --source "s2:3-4"
  [[ "$output" == *duplicate* ]]
}

@test "a MISTAKES_JSONL that cannot be appended to exits non-zero and never says appended" {
  _src_env
  unset CODEX_ROOT
  export MISTAKES_JSONL="$D/a/dir"; mkdir -p "$MISTAKES_JSONL"
  _m --source "s1:1-2"
  [ "$status" -ne 0 ]
  [[ "$output" != *appended\ mistake* ]]
}

@test "an unreadable neighbour mistakes.jsonl is named and does not block the append" {
  _src_env
  jq -nc '{source:"s1:1-2"}' > "$D/b/mistakes.jsonl"
  chmod 000 "$D/b/mistakes.jsonl"
  _m --source "s1:1-2"
  chmod 644 "$D/b/mistakes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$D/b/mistakes.jsonl"* && "$output" == *"duplicate check skipped"* ]]
  [ "$(_rows)" -eq 1 ]
}

@test "an overlapping range in the same session is a duplicate" {
  _src_env
  _m --source "s1:653-670"
  _m --source "s1:660-675"
  [ "$(_rows)" -eq 1 ]
}

@test "a range touching at one line in the same session is a duplicate" {
  _src_env
  _m --source "s1:653-670"
  _m --source "s1:670-675"
  [ "$(_rows)" -eq 1 ]
}

@test "the same range in another session appends" {
  _src_env
  _m --source "s1:653-670"
  _m --source "s2:653-670"
  [ "$(_rows)" -eq 2 ]
}

@test "a range that does not touch, in the same session, appends" {
  _src_env
  _m --source "s1:653-670"
  _m --source "s1:672-680"
  [ "$(_rows)" -eq 2 ]
}

@test "the same range with another category is still a duplicate" {
  _src_env
  _m --source "s1:653-670"
  run bash "$LOG" mistake --category other --trigger t --description d \
    --correction x --severity low --source "s1:653-670"
  [ "$(_rows)" -eq 1 ]
}

@test "a match in another store root's mistakes.jsonl is a duplicate" {
  _src_env
  jq -nc '{ts:"2026-01-02T03:04:05Z",session:"s1",source:"s1:653-670"}' > "$D/b/mistakes.jsonl"
  _m --source "s1:660-675"
  [[ "$output" == *duplicate* ]]
  [ ! -s "$MISTAKES_JSONL" ]
}

@test "rows with no source key never match" {
  _src_env
  jq -nc '{ts:"2026-01-02T03:04:05Z",session:"s1"}' > "$MISTAKES_JSONL"
  _m --source "s1:653-670"
  [ "$(_rows)" -eq 2 ]
}

@test "a refused duplicate leaves the earlier bytes unchanged" {
  _src_env
  _m --source "s1:653-670"
  cp "$MISTAKES_JSONL" "$D/before"
  _m --source "s1:653-670"
  cmp "$D/before" "$MISTAKES_JSONL"
}

@test "an accepted append leaves the earlier bytes unchanged" {
  _src_env
  _m --source "s1:653-670"
  cp "$MISTAKES_JSONL" "$D/before"
  _m --source "s2:1-2"
  [ "$(head -c "$(wc -c < "$D/before")" "$MISTAKES_JSONL" | cmp - "$D/before"; echo $?)" = 0 ]
}

@test "ten parallel identical calls leave one new row and every line parses as JSON" {
  _src_env
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$LOG" mistake --category c --trigger t --description d --correction x \
      --severity low --source "s1:653-670" >/dev/null 2>&1 &
  done
  wait
  [ "$(_rows)" -eq 1 ]
  jq -e . "$MISTAKES_JSONL" >/dev/null
}

@test "a call with only the old flags appends to a file that already holds source rows" {
  _src_env
  jq -nc '{session:"s1",source:"s1:653-670",category:"c"}' > "$MISTAKES_JSONL"
  _m
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 2 ]
}

@test "a failed write is reported as a write failure, not a lock timeout" {
  _src_env
  mkdir "$MISTAKES_JSONL"                   # unwritable target: the append itself fails
  _m
  [ "$status" -ne 0 ]
  [[ "$output" == *"row not appended"* ]]
  [[ "$output" != *"lock"* ]]
}

@test "a --source whose span reaches the cap is refused and appends nothing" {
  _src_env
  _m --source "s1:10-2010"
  [ "$status" -eq 1 ]
  [[ "$output" == *2000* ]]
  [ ! -s "$MISTAKES_JSONL" ]
  _m --source "s1:10-2009"   # control: one under the cap is accepted
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 1 ]
}

@test "a stored wide-span row does not make a narrow new row a duplicate" {
  _src_env
  jq -nc '{ts:"T1",source:"victim:1-999999999"}' > "$MISTAKES_JSONL"
  _m --source "victim:50-60"
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 2 ]
}

@test "a wide-span row in a second store root does not suppress a narrow new row" {
  _src_env
  jq -nc '{ts:"T1",source:"victim:1-999999999"}' > "$D/b/mistakes.jsonl"
  _m --source "victim:50-60"
  [ "$status" -eq 0 ]
  [ "$(_rows)" -eq 1 ]
}
