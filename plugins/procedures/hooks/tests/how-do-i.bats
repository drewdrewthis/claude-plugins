#!/usr/bin/env bats
# Tests for scripts/how-do-i.sh — the end-to-end /how-do-i driver: question ->
# stage 1 (fast model + numbered index -> JSON array of numbers) ->
# compile-records.sh -> stage 2 (strong model + compiled records -> answer).
#
# No test calls a real model. The `claude` invocation is injected via
# HOWDOI_CLAUDE_BIN, pointed at a generic fixture stub (make_stub, below) whose
# behavior per invocation is controlled entirely by files under STUB_DIR — no
# real subprocess semantics are assumed beyond argv/stdin capture and a canned
# stdout/exit code. Pure-logic pieces (response parsing, answer validation,
# timing-line formatting) are exercised through the script's own
# --internal-parse-selection / --internal-validate-answer / --internal-format-timing
# seams as ordinary subprocess calls, so this script's `set -uo pipefail` never
# leaks into the bats process, and so those pieces are testable without any
# dependency on build-record-index.sh or compile-records.sh existing.
#
# Tests that exercise session-cache invalidate/reuse (section h) and the
# --timing real-run label (section i) deliberately make stage 1 return an
# EMPTY selection ("[]"), which short-circuits the run before stage 2 and
# keeps them independent of compile-records.sh. They assert only on
# session-cache artifacts and stub call args/stdin. Section (n) is what pins
# the short-circuit itself.
#
# Run: bats hooks/tests/how-do-i.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/how-do-i.sh"
  TMP="$(mktemp -d)"
  # Isolates how-do-i.sh's CURRENT_ROOTS resolution from whatever
  # CODEX_STORE_ROOTS/CODEX_ROOT happen to be set in the ambient
  # environment: seed_roots_stamp (below) writes a roots.stamp that must
  # match this exactly, or the roots/staleness invalidation gate (section o)
  # wrongly treats every fixture as stale and triggers a real,
  # non-deterministic rebuild.
  unset CODEX_STORE_ROOTS
  export CODEX_ROOT="$TMP/default-root"
  mkdir -p "$CODEX_ROOT"
}

teardown() {
  rm -rf "$TMP"
}

# Pre-seeds a roots.stamp in $1 matching how-do-i.sh's CURRENT_ROOTS under
# this setup()'s isolated CODEX_ROOT, so the roots/staleness invalidation
# gate (section o) treats an already-built index as fresh. Every fixture
# that pre-seeds index.txt/map.tsv to skip the build path calls this too,
# now that a missing stamp alone forces a rebuild.
seed_roots_stamp() {
  local index_dir="$1"
  printf '%s\n%s\n' "${CODEX_STORE_ROOTS:-${CODEX_ROOT:-$HOME/.claude}}" "$(date +%s)" > "$index_dir/roots.stamp"
}

# Generic HOWDOI_CLAUDE_BIN stub. Writes an executable at $1. Its behavior at
# runtime is controlled via env var STUB_DIR (set by the caller when invoking
# how-do-i.sh, NOT at stub-creation time):
#   STUB_DIR/count            running invocation counter (auto-created)
#   STUB_DIR/call-N.args      invocation N's args, one per line
#   STUB_DIR/call-N.stdin     invocation N's stdin (the prompt sent)
#   STUB_DIR/resp-N.json      canned stdout for invocation N (default: empty)
#   STUB_DIR/exit-N           canned exit code for invocation N (default: 0)
make_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
: "${STUB_DIR:?STUB_DIR not set}"
mkdir -p "$STUB_DIR"
n=0
[ -f "$STUB_DIR/count" ] && n="$(cat "$STUB_DIR/count")"
n=$((n + 1))
echo "$n" > "$STUB_DIR/count"
printf '%s\n' "$@" > "$STUB_DIR/call-$n.args"
cat > "$STUB_DIR/call-$n.stdin"
if [ -f "$STUB_DIR/resp-$n.json" ]; then
    cat "$STUB_DIR/resp-$n.json"
fi
ec=0
[ -f "$STUB_DIR/exit-$n" ] && ec="$(cat "$STUB_DIR/exit-$n")"
exit "$ec"
STUB
  chmod +x "$path"
}

# ---------- (a) stage-1 response parsing: fences, bare arrays, structured_output, empty ----------

@test "internal-parse-selection: fenced \`\`\`json[...]\`\`\` reply (no internal whitespace) parses" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "```json[394, 314, 320, 473]```"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 394 314 320 473" ]
}

@test "internal-parse-selection: fenced \`\`\`json ... \`\`\` reply with newlines/spaces parses" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "```json\n[1, 2]\n```"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 1 2" ]
}

@test "internal-parse-selection: bare array reply (no fences) parses" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "[3, 7, 12]"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 3 7 12" ]
}

@test "internal-parse-selection: structured_output.selected (json-schema path) is preferred and parses" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "{\"selected\":[9,4]}", structured_output: {selected: [9, 4]}}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 9 4" ]
}

@test "internal-parse-selection: empty array (nothing relevant) parses to zero numbers, ok" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "[]"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
}

# ---------- (b) is_error is a loud, non-zero failure at both stages ----------

@test "internal-parse-selection: is_error true is a loud, non-zero failure" {
  resp="$TMP/resp.json"
  jq -n '{is_error: true, result: "API rate limited"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is_error"* ]]
}

@test "internal-validate-answer: is_error true is a loud, non-zero failure" {
  resp="$TMP/resp.json"
  jq -n '{is_error: true, result: "downstream failure"}' > "$resp"
  run bash "$SCRIPT" --internal-validate-answer "$resp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is_error"* ]]
}

# ---------- (c) empty stage-2 output is a loud, non-zero failure ----------

@test "internal-validate-answer: empty result text is a loud, non-zero failure" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: ""}' > "$resp"
  run bash "$SCRIPT" --internal-validate-answer "$resp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]
}

@test "internal-validate-answer: whitespace-only result text is a loud, non-zero failure" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "   \n  "}' > "$resp"
  run bash "$SCRIPT" --internal-validate-answer "$resp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]
}

@test "internal-validate-answer: non-empty result text passes through" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "The answer is 42."}' > "$resp"
  run bash "$SCRIPT" --internal-validate-answer "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK The answer is 42." ]
}

# ---------- (d) timing breakdown is reported per stage, cold vs warm labeled ----------

@test "internal-format-timing: wall/boot/api/cache breakdown sums correctly and labels cold" {
  resp="$TMP/resp.json"
  jq -n '{duration_ms: 5000, duration_api_ms: 1200, usage: {cache_read_input_tokens: 36900, cache_creation_input_tokens: 21}}' > "$resp"

  run bash "$SCRIPT" --internal-format-timing select 1 cold 7.500 "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage=select"* ]]
  [[ "$output" == *"attempt=1"* ]]
  [[ "$output" == *"mode=cold"* ]]
  [[ "$output" == *"wall_ms=7500"* ]]
  [[ "$output" == *"cli_duration_ms=5000"* ]]
  [[ "$output" == *"api_ms=1200"* ]]
  [[ "$output" == *"cli_overhead_ms=3800"* ]]
  [[ "$output" == *"spawn_teardown_ms=2500"* ]]
  [[ "$output" == *"cache_read=36900"* ]]
  [[ "$output" == *"cache_creation=21"* ]]
}

@test "internal-format-timing: labels warm distinctly from cold" {
  resp="$TMP/resp.json"
  jq -n '{duration_ms: 900, duration_api_ms: 300, usage: {cache_read_input_tokens: 100, cache_creation_input_tokens: 0}}' > "$resp"

  run bash "$SCRIPT" --internal-format-timing answer 1 warm 2.100 "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=warm"* ]]
  [[ "$output" != *"mode=cold"* ]]
}

@test "internal-format-timing: floors cli_overhead_ms/spawn_teardown_ms at 0 instead of going negative" {
  resp="$TMP/resp.json"
  # A canned duration_ms larger than the measured wall time (e.g. millisecond-
  # boundary rounding noise in real usage) must never surface as a negative
  # "overhead" or "teardown" duration.
  jq -n '{duration_ms: 500, duration_api_ms: 50, usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}' > "$resp"

  run bash "$SCRIPT" --internal-format-timing select 1 cold 0.014 "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wall_ms=14"* ]]
  [[ "$output" == *"cli_duration_ms=500"* ]]
  [[ "$output" == *"cli_overhead_ms=450"* ]]
  [[ "$output" == *"spawn_teardown_ms=0"* ]]
  [[ "$output" != *"spawn_teardown_ms=-"* ]]
}

# ---------- (e) stage 1 prose reply retries once, then fails loudly ----------

@test "stage 1 prose reply triggers exactly one retry, then a loud non-zero failure" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  prose_resp="$TMP/prose.json"
  jq -n '{is_error: false, session_id: "sess-prose", result: "I need to read this carefully before responding to make sure I give a good answer.", duration_ms: 500, duration_api_ms: 400, usage: {input_tokens: 5, output_tokens: 20, cache_creation_input_tokens: 0, cache_read_input_tokens: 0}}' > "$prose_resp"
  cp "$prose_resp" "$stub_dir/resp-1.json"
  cp "$prose_resp" "$stub_dir/resp-2.json"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n2 :: another record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n2\tid-two\tpath/two\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "what is x" --index-dir "$index_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stage 1"* ]]
  [[ "$output" == *"2 attempt"* ]]

  [ "$(cat "$stub_dir/count")" = "2" ]
}

# ---------- (f) is_error at stage 1 fails immediately, consumes no retry ----------

@test "stage 1 is_error true fails the run loudly and non-zero, with no retry consumed" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  jq -n '{is_error: true, result: "upstream failure", session_id: "s1"}' > "$stub_dir/resp-1.json"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "what is x" --index-dir "$index_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stage 1"* ]]

  [ "$(cat "$stub_dir/count")" = "1" ]
}

# ---------- (g) --dry-run makes zero calls, prints both prompts ----------

@test "--dry-run makes zero calls to the stub and prints both prompts (plain text)" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record about widgets\n2 :: another record about gadgets\n' > "$index_dir/index.txt"
  # map.tsv deliberately NOT created: --dry-run must only require index.txt.

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "how do widgets work" --index-dir "$index_dir" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"STAGE 1 PROMPT"* ]]
  [[ "$output" == *"STAGE 2 PROMPT"* ]]
  [[ "$output" == *"how do widgets work"* ]]

  [ ! -f "$stub_dir/count" ]
}

@test "--dry-run --json prints a JSON object with both prompts and makes zero calls" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dry_run == true' >/dev/null
  echo "$output" | jq -e '.stage1_prompt | contains("q")' >/dev/null
  echo "$output" | jq -e '.stage2_prompt_template | length > 0' >/dev/null

  [ ! -f "$stub_dir/count" ]
}

# ---------- (h) session-cache: index change invalidates, unchanged index reuses ----------

@test "a changed index.txt invalidates the stored session id and forces a re-prime" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: new content v2\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"
  echo "stale-session-id" > "$index_dir/session.id"
  echo "deadbeef-not-matching-anything" > "$index_dir/session.fingerprint"

  jq -n '{is_error: false, session_id: "new-session-xyz", result: "[]"}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir"
  # What's under test here is the session-cache behavior only; the empty
  # selection just keeps the run short (see section n).

  [ -f "$stub_dir/call-1.args" ]
  ! grep -q -- '--resume' "$stub_dir/call-1.args"
  [ -f "$stub_dir/call-1.stdin" ]
  grep -q "Index:" "$stub_dir/call-1.stdin"

  [ "$(cat "$index_dir/session.id")" = "new-session-xyz" ]
  expected_fp="$(shasum -a 256 "$index_dir/index.txt" | awk '{print $1}')"
  [ "$(cat "$index_dir/session.fingerprint")" = "$expected_fp" ]
}

@test "an unchanged index reuses the stored session id via --resume" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: stable content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  fp="$(shasum -a 256 "$index_dir/index.txt" | awk '{print $1}')"
  echo "reused-session-123" > "$index_dir/session.id"
  printf '%s' "$fp" > "$index_dir/session.fingerprint"

  jq -n '{is_error: false, session_id: "reused-session-123", result: "[]"}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [ -f "$stub_dir/call-1.args" ]
  grep -q -- '--resume' "$stub_dir/call-1.args"
  grep -q "reused-session-123" "$stub_dir/call-1.args"

  [ -f "$stub_dir/call-1.stdin" ]
  ! grep -q "^Index:" "$stub_dir/call-1.stdin"
  grep -q "established earlier in this session" "$stub_dir/call-1.stdin"

  [ "$(cat "$index_dir/session.id")" = "reused-session-123" ]
  [ "$(cat "$index_dir/session.fingerprint")" = "$fp" ]
}

@test "a warm run's returned session_id is re-persisted too, in case the CLI ever rotates it on resume" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: stable content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  fp="$(shasum -a 256 "$index_dir/index.txt" | awk '{print $1}')"
  echo "original-session-id" > "$index_dir/session.id"
  printf '%s' "$fp" > "$index_dir/session.fingerprint"

  # Stub returns a DIFFERENT session_id than the one being resumed, simulating
  # a hypothetical CLI that rotates ids across --resume.
  jq -n '{is_error: false, session_id: "rotated-session-id", result: "[]"}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  # The warm path really was taken (resumed the ORIGINAL id)...
  grep -q "original-session-id" "$stub_dir/call-1.args"
  # ...but the id stored for NEXT time follows whatever the CLI returned.
  [ "$(cat "$index_dir/session.id")" = "rotated-session-id" ]
  [ "$(cat "$index_dir/session.fingerprint")" = "$fp" ]
}

# ---------- (i) --timing labels a real (stubbed) run cold vs warm ----------

@test "--timing prints a stage=select line labeled mode=cold on a real cold (stubbed) run" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  jq -n '{is_error: false, session_id: "s1", result: "[]", duration_ms: 900, duration_api_ms: 300, usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 500}}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --timing

  [[ "$output" == *"[how-do-i timing] stage=select attempt=1 mode=cold"* ]]
}

@test "--timing prints a stage=select line labeled mode=warm on a real warm (stubbed) run" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"
  fp="$(shasum -a 256 "$index_dir/index.txt" | awk '{print $1}')"
  echo "warm-sess" > "$index_dir/session.id"
  printf '%s' "$fp" > "$index_dir/session.fingerprint"

  jq -n '{is_error: false, session_id: "warm-sess", result: "[]", duration_ms: 400, duration_api_ms: 150, usage: {cache_read_input_tokens: 36900, cache_creation_input_tokens: 21}}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --timing

  [[ "$output" == *"[how-do-i timing] stage=select attempt=1 mode=warm"* ]]
}

# ---------- (j) flag validation / usage errors ----------

@test "--rebuild and --dry-run together is a usage error" {
  run bash "$SCRIPT" --question "q" --rebuild --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"incompatible"* ]]
}

@test "missing --question and --question-file is a usage error" {
  run bash "$SCRIPT" --index-dir "$TMP/whatever"
  [ "$status" -eq 2 ]
}

@test "--question and --question-file together is a usage error" {
  qf="$TMP/q.txt"
  echo "from file" > "$qf"
  run bash "$SCRIPT" --question "from flag" --question-file "$qf"
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: how-do-i.sh"* ]]
}

# ---------- (k) missing claude binary aborts loudly, writes nothing to the cache ----------

@test "an unresolvable claude binary aborts loudly and never writes session cache files" {
  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"
  nonexistent="$TMP/does-not-exist/claude"

  run env HOWDOI_CLAUDE_BIN="$nonexistent" bash "$SCRIPT" --question "q" --index-dir "$index_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  [ ! -f "$index_dir/session.id" ]
}

# PLUGIN ADAPTATION: no upstream counterpart — covers the plugin-local gateway
# fallback in scripts/how-do-i.sh, which orchard-codex's copy does not have.
@test "a raw-claude spawn failure retries the attempt THROUGH the orwrap wrapper, not raw claude again" {
  # Regression: the fallback used to reassign a local word-array that
  # run_claude_call never reads, so the "retrying via orwrap" retry silently
  # re-ran raw `claude` and the run died anyway.
  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  bin="$TMP/bin"; mkdir -p "$bin"
  log="$TMP/spawn.log"

  cat > "$bin/claude" <<EOF
#!/usr/bin/env bash
echo "raw-claude" >> "$log"
echo "boom: unrecognized_model" >&2
exit 1
EOF
  cat > "$bin/orwrap" <<EOF
#!/usr/bin/env bash
echo "orwrap \$1" >> "$log"
cat > /dev/null
printf '%s' '{"result":"[1]","session_id":"s1","is_error":false}'
EOF
  chmod +x "$bin/claude" "$bin/orwrap"

  run env PATH="$bin:$PATH" HOWDOI_CLAUDE_BIN= bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [ -f "$log" ]
  # first spawn raw, second spawn through the wrapper with `claude` as argv[1]
  [ "$(sed -n '1p' "$log")" = "raw-claude" ]
  [ "$(sed -n '2p' "$log")" = "orwrap claude" ]
  # and it must not have fallen back to raw claude a second time
  [ "$(grep -c 'raw-claude' "$log")" -eq 1 ]
}

# ---------- (l) stage-1 replies with trailing prose still yield a selection ----------
#
# The selector runs on a fast model instructed to reply with ONLY a JSON array;
# in practice it sometimes appends invented explanation after the array. Parsing
# must key off the first well-formed JSON array of integers in the reply rather
# than requiring the whole reply to be bare JSON.

@test "internal-parse-selection: an empty array followed by trailing prose parses to zero numbers, ok" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "[]\n\nNone of the records in the index are relevant to this question."}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
  [[ "$output" != *[0-9]* ]]
}

@test "internal-parse-selection: a populated array followed by trailing prose parses to that array" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "[4, 8]\n\nThese two records cover the procedure you asked about."}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 4 8" ]
}

@test "internal-parse-selection: a fenced array followed by trailing prose parses to that array" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "```json\n[7]\n```\n\nRecord 7 is the only relevant one."}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  [ "$output" = "OK 7" ]
}

@test "internal-parse-selection: prose with no JSON array at all is still unparseable" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "I need to read this carefully before responding."}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL unparseable" ]
}

# ---------- (m) reason-code regression guard for every accepted/rejected shape ----------
#
# Reason codes are load-bearing: the stage-1 retry loop branches on them
# ("is_error" dies immediately; everything else consumes the retry budget).
# These pin the reason strings and branch ORDER byte-for-byte.

@test "internal-parse-selection: object-with-selected in text still takes the text-object path" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "{\"selected\": [5, 6]}"}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 0 ]
  # Not "OK 5" — the object path must win over scavenging the first array
  # literal out of the same text.
  [ "$output" = "OK 5 6" ]
}

@test "internal-parse-selection: malformed structured_output.selected still reports structured_output-shape" {
  resp="$TMP/resp.json"
  jq -n '{is_error: false, result: "[1, 2]", structured_output: {selected: "not-an-array"}}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 1 ]
  # structured_output is preferred over .result and its malformed-ness is NOT
  # rescued by the text path, however parseable .result happens to be.
  [ "$output" = "FAIL structured_output-shape" ]
}

@test "internal-parse-selection: is_error still reports exactly is_error, ahead of every other branch" {
  resp="$TMP/resp.json"
  jq -n '{is_error: true, result: "[1, 2]", structured_output: {selected: [1, 2]}}' > "$resp"
  run bash "$SCRIPT" --internal-parse-selection "$resp"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL is_error" ]
}

# ---------- (n) an empty selection is a valid "nothing relevant" answer, not a failure ----------
#
# Regression (fm.how-do-i-corpus-index-blind): stage 1 correctly selecting
# nothing used to build an empty --nums and hand it to compile-records.sh, whose
# own contract rightly rejects an empty selection — so the whole pipeline exited
# 1 on a legitimate "no relevant records" result. The guard belongs in the
# CALLER; compile-records.sh's contract is unchanged.

# Copies how-do-i.sh — plus the real lib/stores.sh, so its roots/staleness
# probe (section o) resolves — into an isolated scripts dir next to a
# SENTINEL compile-records.sh that logs its argv. SCRIPT_DIR is resolved
# from BASH_SOURCE at runtime, so the copy looks for siblings here — which
# makes "compile-records.sh was never invoked" directly observable rather
# than inferred.
make_sentinel_scripts_dir() {
  local dir="$1" log="$2"
  mkdir -p "$dir/lib"
  cp "$SCRIPT" "$dir/how-do-i.sh"
  cp "$(dirname "$SCRIPT")/lib/stores.sh" "$dir/lib/stores.sh"
  cat > "$dir/compile-records.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$log"
echo "=== compiled record text ==="
EOF
  chmod +x "$dir/compile-records.sh"
}

@test "an empty stage-1 selection exits 0 with a NOT FOUND answer and never invokes compile-records.sh" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  compile_log="$TMP/compile.log"
  make_sentinel_scripts_dir "$scripts_dir" "$compile_log"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT FOUND"* ]]
  [ ! -f "$compile_log" ]
  # stage 2 is skipped too: exactly the one stage-1 call was made.
  [ "$(cat "$stub_dir/count")" = "1" ]
}

@test "an empty stage-1 selection produced by trailing prose also exits 0, not a stage-1 death" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  jq -n '{is_error: false, session_id: "s1", result: "[]\n\nNothing in the index is relevant."}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT FOUND"* ]]
  # One call only: no retry was consumed, so the trailing prose never made it
  # look unparseable.
  [ "$(cat "$stub_dir/count")" = "1" ]
}

@test "--json on an empty selection reports not_found with empty selection arrays and a null answer stage" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  jq -n '{is_error: false, session_id: "s1", result: "[]", duration_ms: 400, duration_api_ms: 150, usage: {input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}' > "$stub_dir/resp-1.json"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir" --json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.not_found == true' >/dev/null
  echo "$output" | jq -e '.selected_numbers == []' >/dev/null
  echo "$output" | jq -e '.resolved_ids == []' >/dev/null
  echo "$output" | jq -e '.answer | test("NOT FOUND")' >/dev/null
  # stage 1 metadata is still reported; stage 2 never ran.
  echo "$output" | jq -e '.stages.select.attempts == 1' >/dev/null
  echo "$output" | jq -e '.stages.answer == null' >/dev/null
}

@test "a NON-empty selection still invokes compile-records.sh with the selected numbers" {
  # Guards the short-circuit against over-triggering.
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n2 :: another record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n2\tid-two\tpath/two\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"

  jq -n '{is_error: false, session_id: "s1", result: "[2, 1]"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s2", result: "The answer, per id-two."}' > "$stub_dir/resp-2.json"

  scripts_dir="$TMP/scripts"
  compile_log="$TMP/compile.log"
  make_sentinel_scripts_dir "$scripts_dir" "$compile_log"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ "$output" = "The answer, per id-two." ]
  [ -f "$compile_log" ]
  grep -q -- '--nums' "$compile_log"
  grep -q '^2,1$' "$compile_log"
}

# ---------- (o) roots/staleness cache invalidation ----------
#
# Regression: how-do-i.sh used to rebuild the index only when index.txt/
# map.tsv were MISSING, never on a CODEX_STORE_ROOTS change or on new/changed
# record files — so a split-store cutover kept answering from a stale
# single-root index indefinitely, even after the env var was set and the
# cache had already been rebuilt at least once. seed_roots_stamp (setup(),
# above) keeps every OTHER fixture's roots.stamp matching CURRENT_ROOTS so
# its behavior is unchanged; these three pin the new gate itself.

# Copies how-do-i.sh — plus the real lib/stores.sh, needed by its
# roots/staleness probe — into an isolated scripts dir next to a SENTINEL
# build-record-index.sh that logs its argv to $2 and writes a minimal valid
# index.txt/map.tsv under whatever --out DIR it receives, so "a rebuild was
# attempted" is observable via $2's existence rather than inferred from
# index.txt content alone.
make_build_sentinel_scripts_dir() {
  local dir="$1" log="$2"
  mkdir -p "$dir/lib"
  cp "$SCRIPT" "$dir/how-do-i.sh"
  cp "$(dirname "$SCRIPT")/lib/stores.sh" "$dir/lib/stores.sh"
  cat > "$dir/build-record-index.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$log"
out="\$2"
mkdir -p "\$out"
printf '1 :: rebuilt content\n' > "\$out/index.txt"
printf '1\tid-one\tpath/one\n' > "\$out/map.tsv"
EOF
  chmod +x "$dir/build-record-index.sh"
}

@test "a roots.stamp recording different roots than CODEX_ROOT forces a rebuild" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: stale content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  # Stamp names a DIFFERENT roots string than CODEX_ROOT resolves to.
  printf '%s\n%s\n' "/some/old/roots" "1000000000" > "$index_dir/roots.stamp"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ -f "$build_log" ]
  grep -q -- '--out' "$build_log"
  grep -q "rebuilt content" "$index_dir/index.txt"
  [ "$(sed -n '1p' "$index_dir/roots.stamp")" = "$CODEX_ROOT" ]
}

@test "a *.md under CODEX_ROOT newer than index.txt forces a rebuild even with a matching roots.stamp" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: stale content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  touch -t 202001010000 "$index_dir/index.txt"
  seed_roots_stamp "$index_dir"

  # A record file that changed after the index was built.
  printf '# changed record\n' > "$CODEX_ROOT/changed.md"
  touch -t 202501010000 "$CODEX_ROOT/changed.md"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ -f "$build_log" ]
  grep -q "rebuilt content" "$index_dir/index.txt"
}

@test "an up-to-date index with a matching roots.stamp and no newer records is reused, not rebuilt" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: fresh content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  touch -t 202501010000 "$index_dir/index.txt"
  seed_roots_stamp "$index_dir"

  # A record file that predates the index — must NOT trigger a rebuild.
  printf '# old record\n' > "$CODEX_ROOT/old.md"
  touch -t 202001010000 "$CODEX_ROOT/old.md"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ ! -f "$build_log" ]
  grep -q "fresh content" "$index_dir/index.txt"
}
