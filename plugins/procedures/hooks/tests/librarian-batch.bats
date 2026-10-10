#!/usr/bin/env bats
# librarian-batch.sh issues one bounded batch of unread transcript lines;
# librarian-advance.sh refuses to move a cursor outside the range the current
# manifest issued. What is enforced: a cursor never passes the end of what was
# issued. That the issued lines were actually read is the librarian prompt's
# rule, not something these scripts can check.
#
# Run: bats hooks/tests/librarian-batch.bats

load helpers/common

setup() {
  SCRIPTS="$BATS_TEST_DIRNAME/../../scripts"
  HOOK="$BATS_TEST_DIRNAME/../librarian-poke.sh"
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
  _touch_ago "$f" $(( $3 * 86400 ))
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

@test "a zero or leading-zero budget is rejected" {
  _transcript t 3 1
  for b in 0 00 0200000; do
    LIBRARIAN_BATCH_BYTES=$b run bash "$SCRIPTS/librarian-batch.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"positive integer"* ]]
  done
}

# _shim <tool> <arg> <marker> <failing-body> — a PATH shim for <tool>: when
# called with <arg> (the distill call) and its stdin contains <marker>, it runs
# <failing-body>; every other call goes straight to the real tool.
_shim() {
  local real; real="$(command -v "$1")"
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/$1" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *"$2"* ]] || exec "$real" "\$@"
in="\$(cat)"
if [[ "\$in" == *$3* ]]; then $4; fi
printf '%s\n' "\$in" | "$real" "\$@"
EOF
  chmod +x "$HOME/bin/$1"
  export PATH="$HOME/bin:$PATH"
}

@test "a jq failure skips that transcript with a message; younger ones are still issued" {
  printf '{"type":"user","message":{"content":"BOOM"}}\n' > "$PROJ/bad.jsonl"
  _touch_ago "$PROJ/bad.jsonl" 172800
  _transcript good 2 1
  _shim jq ' -R ' BOOM 'exit 5'
  _batch
  [[ "$output" == *"skipped $PROJ/bad.jsonl"* ]]
  [ -z "$(_issued bad)" ]
  [ "$(_issued good)" = "0 2" ]
  ! grep -q BOOM "$PROCEDURES_STATE_DIR/batch.txt" || false
}

@test "a malformed END from the distill skips that transcript; younger ones are still issued" {
  printf '{"type":"user","message":{"content":"GARBAGE"}}\n' > "$PROJ/bad.jsonl"
  _touch_ago "$PROJ/bad.jsonl" 172800
  _transcript good 2 1
  _shim awk 'hdr=' GARBAGE 'echo "END x 1e9"; exit 0'
  _batch
  [[ "$output" == *"skipped $PROJ/bad.jsonl"* ]]
  [ -z "$(_issued bad)" ]
  [ "$(_issued good)" = "0 2" ]
}

@test "the librarian's own drain sessions are never issued and get no cursor" {
  { printf '{"type":"agent-setting","agentSetting":"procedures:librarian","sessionId":"x"}\n'
    printf '{"type":"user","message":{"content":"Drain the transcript queue."}}\n'; } > "$PROJ/drain.jsonl"
  { printf '{"type":"agent-setting","agentSetting":"claude","sessionId":"y"}\n'
    printf '{"type":"user","message":{"content":"real work"}}\n'; } > "$PROJ/other.jsonl"
  _transcript plain 2 1
  _batch
  [ -z "$(_issued drain)" ]
  [ ! -e "$PROCEDURES_STATE_DIR/cursors/drain.line" ]
  [ "$(_issued other)" = "0 2" ]
  [ "$(_issued plain)" = "0 2" ]
  ! grep -q 'Drain the transcript queue' "$PROCEDURES_STATE_DIR/batch.txt" || false
}

# claude#41: the worklog judge's `claude -p` run leaves a transcript whose first
# line is its enqueue record. Those are the judge's input, not a session.
_judge_enqueue() {
  printf '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-06T10:00:00Z","content":"CANDIDATES (uuid, where, kind, text):\\nu1\\tTHIS-TURN\\tuser\\tjudge-body-marker"}\n'
}

@test "a worklog judge transcript is never issued and gets no cursor" {
  { _judge_enqueue
    printf '{"type":"user","message":{"content":"judge-body-marker"}}\n'; } > "$PROJ/judge.jsonl"
  _transcript plain 2 1
  _batch
  [ -z "$(_issued judge)" ]
  [ ! -e "$PROCEDURES_STATE_DIR/cursors/judge.line" ]
  [ "$(_issued plain)" = "0 2" ]
}

@test "a judge transcript's text is absent from the batch" {
  { _judge_enqueue
    printf '{"type":"user","message":{"content":"judge-body-marker"}}\n'; } > "$PROJ/judge.jsonl"
  _transcript plain 2 1
  _batch
  ! grep -q 'judge-body-marker' "$PROCEDURES_STATE_DIR/batch.txt" || false
}

@test "a session transcript holding that text on a later line is still issued" {
  { printf '{"type":"user","message":{"content":"real work"}}\n'
    _judge_enqueue; } > "$PROJ/session.jsonl"
  _batch
  [ "$(_issued session)" = "0 2" ]
}

@test "an empty transcript file does not abort the batch" {
  : > "$PROJ/empty.jsonl"
  _transcript plain 2 1
  _batch
  [ "$(_issued plain)" = "0 2" ]
}

@test "a transcript whose first line does not parse does not abort the batch" {
  { printf 'not json {{queue-operation\n'
    printf '{"type":"user","message":{"content":"hi"}}\n'; } > "$PROJ/garbled.jsonl"
  _transcript plain 2 1
  _batch
  [ "$(_issued plain)" = "0 2" ]
}

@test "the judge heading literal is the same in librarian-batch.sh and worklog-record.sh" {
  local w="$BATS_TEST_DIRNAME/../../../worklog/hooks/worklog-record.sh"
  [ -f "$w" ] || skip "worklog plugin dir absent: $w"
  local h='CANDIDATES (uuid, where, kind, text):'
  grep -qF "$h" "$SCRIPTS/librarian-batch.sh"
  grep -qF "$h" "$w"
}

# ---------- --pressure-check: abort the batch under pressure (#166) ----------
#
# The batch runs `bash <path> --load-ok </dev/null` at the top of a corpus-loop
# iteration once LIBRARIAN_RECHECK_SECS have passed (0 = every iteration, the
# first included). Exit 75 aborts the batch; every other exit means proceed.

# _check <name> <body> — a check script that records each call, then runs <body>.
_check() {
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/%s.calls"\n%s\n' "$HOME" "$1" "$2" > "$HOME/$1"
  chmod +x "$HOME/$1"
}
_calls() { if [ -f "$HOME/$1.calls" ]; then wc -l < "$HOME/$1.calls" | tr -d " "; else echo 0; fi; }
_pc() { LIBRARIAN_RECHECK_SECS="${RECHECK-0}" run bash "$SCRIPTS/librarian-batch.sh" --pressure-check "$1"; }

@test "no --pressure-check: the batch ignores pressure and issues both ranges" {
  _transcript a 2 2
  _transcript b 2 1
  printf '50.00 0.50 0.10 1/200 123\n' > "$HOME/loadavg"
  export LP_LOADAVG_FILE="$HOME/loadavg" LP_STAT_FILE="$HOME/absent-stat"
  _batch
  [ "$(_issued a)" = "0 2" ]
  [ "$(_issued b)" = "0 2" ]
}

@test "check exits 75: the batch exits 75, leaves no manifest or partial output, and prints a deferred line" {
  _transcript a 2 2; _transcript b 2 1
  _check c75 'exit 75'
  _pc "$HOME/c75"
  [ "$status" -eq 75 ]                           # a real defer, not an argument error
  [ ! -e "$PROCEDURES_STATE_DIR/batch.manifest" ]
  [ ! -e "$PROCEDURES_STATE_DIR/batch.manifest.tmp" ]
  [ ! -e "$PROCEDURES_STATE_DIR/batch.txt.part" ]
  [ ! -s "$PROCEDURES_STATE_DIR/batch.txt" ]
  [[ "$output" == *"librarian-batch: deferred"* ]]
}

@test "check exits 75: a manifest from an earlier batch is gone, not left to be advanced" {
  _transcript a 2 2; _transcript b 2 1
  _batch
  _check c75 'exit 75'
  _pc "$HOME/c75"
  [ "$status" -eq 75 ]                           # a real defer, not an argument error
  [ ! -e "$PROCEDURES_STATE_DIR/batch.manifest" ]
}

@test "check exits 1 or 127: the batch proceeds and issues both ranges" {
  _transcript a 2 2; _transcript b 2 1
  local rc
  for rc in 1 127; do
    _check "c$rc" "exit $rc"
    _pc "$HOME/c$rc"
    [ "$status" -eq 0 ]
    [ "$(_issued a)" = "0 2" ]
    [ "$(_issued b)" = "0 2" ]
  done
}

@test "check path missing: the batch proceeds and issues both ranges" {
  _transcript a 2 2; _transcript b 2 1
  _pc "$HOME/does-not-exist"
  [ "$status" -eq 0 ]
  [ "$(_issued a)" = "0 2" ]
  [ "$(_issued b)" = "0 2" ]
}

@test "check that drains stdin and exits 0: the corpus list is untouched, both ranges issued" {
  _transcript a 2 2; _transcript b 2 1
  _check cat0 'cat > /dev/null; exit 0'
  _pc "$HOME/cat0"
  [ "$status" -eq 0 ]
  [ "$(_issued a)" = "0 2" ]
  [ "$(_issued b)" = "0 2" ]
}

@test "interval 0: the check runs at every iteration, the first included" {
  _transcript a 2 2; _transcript b 2 1
  _check c0 'exit 0'
  _pc "$HOME/c0"
  [ "$(_calls c0)" -eq 2 ]
}

@test "interval 0: the check is invoked as '--load-ok'" {
  _transcript a 2 2
  _check c0 'exit 0'
  _pc "$HOME/c0"
  [ "$(head -n 1 "$HOME/c0.calls")" = "--load-ok" ]
}

@test "a long interval: the check never runs in a fast batch" {
  _transcript a 2 2; _transcript b 2 1
  _check c0 'exit 75'
  RECHECK=3600 _pc "$HOME/c0"
  [ "$status" -eq 0 ]
  [ "$(_calls c0)" -eq 0 ]
}

@test "a non-numeric interval falls back to 5s: no check in a fast batch, both ranges issued" {
  _transcript a 2 2; _transcript b 2 1
  _check c0 'exit 0'
  RECHECK=nope _pc "$HOME/c0"
  [ "$status" -eq 0 ]
  [ "$(_calls c0)" -eq 0 ]                       # a fallback of 0 would call it per iteration
  [ "$(_issued a)" = "0 2" ]
  [ "$(_issued b)" = "0 2" ]
}

@test "the check also runs for fully-read transcripts, not only unread ones" {
  _transcript a 2 2; _transcript b 2 1
  mkdir -p "$PROCEDURES_STATE_DIR/cursors"
  echo 2 > "$PROCEDURES_STATE_DIR/cursors/a.line"
  echo 2 > "$PROCEDURES_STATE_DIR/cursors/b.line"
  _check c0 'exit 0'
  _pc "$HOME/c0"
  [ "$(_calls c0)" -eq 2 ]
}

# AC 8, batch level: the real hook as the check, with no pressure files at all
# (the macOS shape), still lets the batch finish.
@test "hook as the check with both pressure files absent: re-checks run per file and both ranges are issued" {
  _transcript a 2 2; _transcript b 2 1
  export LP_LOADAVG_FILE="$HOME/absent-loadavg" LP_STAT_FILE="$HOME/absent-stat" LP_STAT_SAMPLE_SLEEP=true
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/wrap.calls"\nexec bash "%s" "$@"\n' "$HOME" "$HOOK" > "$HOME/wrap"
  _pc "$HOME/wrap"
  [ "$status" -eq 0 ]
  [ "$(_calls wrap)" -eq 2 ]
  [ "$(_issued a)" = "0 2" ]
  [ "$(_issued b)" = "0 2" ]
}

@test "a batch that already filled its budget is not discarded by a late check" {
  _transcript a 1 2; _transcript b 2 1       # a ends whole, so the loop reaches b
  _check once 'n=$(wc -l < "'"$HOME"'/once.calls"); [ "$n" -gt 1 ] && exit 75; exit 0'
  LIBRARIAN_BATCH_BYTES=100 RECHECK=0 _pc "$HOME/once"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PROCEDURES_STATE_DIR/batch.manifest" | tr -d ' ')" -eq 1 ]
}

@test "--pressure-check with no value fails and names the missing path" {
  run bash "$SCRIPTS/librarian-batch.sh" --pressure-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a path"* ]]
}
