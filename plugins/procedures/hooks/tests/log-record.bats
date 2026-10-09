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
