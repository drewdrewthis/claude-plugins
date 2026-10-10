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
# Tests of the session-free stage 1 (section h, issue #198), the mode=n/a
# --timing/--json label (section i) and the failure/leftover checks (section p)
# mostly make stage 1 return an EMPTY selection ("[]"), which short-circuits
# the run before stage 2 and keeps them independent of compile-records.sh.
# They assert on stub call args/stdin, the system-prompt file the stub copies
# at call time (call-N.system), the CLAUDE_CODE_DISABLE_CLAUDE_MDS value the
# stub records (call-N.env) and leftover state. Section (n) pins the
# short-circuit itself.
#
# Run: bats hooks/tests/how-do-i.bats

# `run --separate-stderr` below needs bats 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/how-do-i.sh"
  TMP="$(mktemp -d)"
  # Isolates how-do-i.sh's CURRENT_ROOTS resolution (_stores_resolve_roots_spec)
  # from the ambient machine: seed_roots_stamp (below) writes a roots.stamp that
  # must match it exactly, or the roots/staleness invalidation gate (section o)
  # wrongly treats every fixture as stale and triggers a real,
  # non-deterministic rebuild. Each pin disables one resolver tier:
  #   unset CODEX_STORE_ROOTS   -> the env tier
  #   CLAUDE_CONFIG_DIR (empty) -> the settings.json tier
  #   KNOWLEDGE_HOME (empty)    -> the ~/.knowledge config.json AND modules/
  #                                auto-discovery tiers (a populated real
  #                                ~/.knowledge outranks CODEX_ROOT and made 9
  #                                tests rebuild against the real corpus)
  #   CODEX_ROOT (scratch dir)  -> the one tier left, so fixtures are deterministic
  # PROCEDURES_STATE_DIR is unset so no state-dir override leaks in either.
  unset CODEX_STORE_ROOTS PROCEDURES_STATE_DIR
  export KNOWLEDGE_HOME="$TMP/knowledge-home"
  export CLAUDE_CONFIG_DIR="$TMP/claude-config"
  mkdir -p "$KNOWLEDGE_HOME" "$CLAUDE_CONFIG_DIR"
  export CODEX_ROOT="$TMP/default-root"
  mkdir -p "$CODEX_ROOT"
}

teardown() {
  rm -rf "$TMP"
}

# Pre-seeds a roots.stamp in $1 matching how-do-i.sh's CURRENT_ROOTS under
# the environment the caller has right now, so the roots/staleness invalidation
# gate (section o) treats an already-built index as fresh. Every fixture
# that pre-seeds index.txt/map.tsv to skip the build path calls this too,
# now that a missing stamp alone forces a rebuild.
#
# The roots string comes from the real resolver, never a hand-copied
# precedence (the copy drifted when the ~/.knowledge tiers landed). It runs in
# a SUBSHELL because sourcing stores.sh executes module-level code that must
# not touch this bats process; the child inherits the caller's exported env,
# including a per-call `CLAUDE_CONFIG_DIR=x seed_roots_stamp ...` override.
seed_roots_stamp() {
  local index_dir="$1"
  local roots_spec
  roots_spec="$(bash -c 'source "$1"; _stores_resolve_roots_spec' _ \
    "$BATS_TEST_DIRNAME/../../scripts/lib/stores.sh")"
  # A broken resolver must fail here, at the first fixture, not as a dozen
  # unrelated how-do-i failures downstream.
  [ -n "$roots_spec" ]
  printf '%s\n%s\n' "$roots_spec" "$(date +%s)" > "$index_dir/roots.stamp"
}

# Generic HOWDOI_CLAUDE_BIN stub. Writes an executable at $1. Its behavior at
# runtime is controlled via env var STUB_DIR (set by the caller when invoking
# how-do-i.sh, NOT at stub-creation time):
#   STUB_DIR/count            running invocation counter (auto-created)
#   STUB_DIR/call-N.args      invocation N's args, one per line
#   STUB_DIR/call-N.stdin     invocation N's stdin (the prompt sent)
#   STUB_DIR/call-N.system    copy of the file named after --system-prompt-file,
#                             taken AT CALL TIME (the script removes its work dir on exit)
#   STUB_DIR/call-N.env       $CLAUDE_CODE_DISABLE_CLAUDE_MDS as seen by invocation N
#   STUB_DIR/stderr-N         text echoed to stderr by invocation N (default: none)
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
printf '%s' "${CLAUDE_CODE_DISABLE_CLAUDE_MDS-}" > "$STUB_DIR/call-$n.env"
prev=""
for a in "$@"; do
    if [ "$prev" = "--system-prompt-file" ] && [ -f "$a" ]; then
        cp "$a" "$STUB_DIR/call-$n.system"
    fi
    prev="$a"
done
[ -f "$STUB_DIR/stderr-$n" ] && cat "$STUB_DIR/stderr-$n" >&2
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

# ---------- (d) timing breakdown is reported per stage ----------

@test "internal-format-timing: wall/boot/api/cache breakdown sums correctly and carries the mode label" {
  resp="$TMP/resp.json"
  jq -n '{duration_ms: 5000, duration_api_ms: 1200, usage: {cache_read_input_tokens: 36900, cache_creation_input_tokens: 21}}' > "$resp"

  run bash "$SCRIPT" --internal-format-timing select 1 n/a 7.500 "$resp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage=select"* ]]
  [[ "$output" == *"attempt=1"* ]]
  [[ "$output" == *"mode=n/a"* ]]
  [[ "$output" == *"wall_ms=7500"* ]]
  [[ "$output" == *"cli_duration_ms=5000"* ]]
  [[ "$output" == *"api_ms=1200"* ]]
  [[ "$output" == *"cli_overhead_ms=3800"* ]]
  [[ "$output" == *"spawn_teardown_ms=2500"* ]]
  [[ "$output" == *"cache_read=36900"* ]]
  [[ "$output" == *"cache_creation=21"* ]]
}

@test "internal-format-timing: floors cli_overhead_ms/spawn_teardown_ms at 0 instead of going negative" {
  resp="$TMP/resp.json"
  # A canned duration_ms larger than the measured wall time (e.g. millisecond-
  # boundary rounding noise in real usage) must never surface as a negative
  # "overhead" or "teardown" duration.
  jq -n '{duration_ms: 500, duration_api_ms: 50, usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}' > "$resp"

  run bash "$SCRIPT" --internal-format-timing select 1 n/a 0.014 "$resp"
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

@test "--dry-run plain text prints a stage-1 SYSTEM prompt section with the instruction" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record about widgets\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run

  [[ "$output" == *"STAGE 1 SYSTEM PROMPT"* ]]
  [[ "$output" == *"choosing which records from an index are relevant"* ]]
}

@test "--dry-run plain text prints the Index in the stage-1 system prompt section" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record about widgets\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run

  [[ "$output" == *"Index:"*"1 :: some record about widgets"* ]]
}

@test "--dry-run plain text reports mode: n/a" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run

  [[ "$output" == *"mode: n/a"* ]]
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

@test "--dry-run --json carries stage1_system_prompt with the instruction and the index" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record about widgets\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json

  echo "$output" | jq -e '.stage1_system_prompt | contains("choosing which records") and contains("Index:\n1 :: some record about widgets")' >/dev/null
}

@test "--dry-run --json stage1_prompt is the question with no Index: block" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record about widgets\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "how do widgets work" --index-dir "$index_dir" --dry-run --json

  echo "$output" | jq -e '(.stage1_prompt | contains("how do widgets work")) and (.stage1_prompt | contains("Index:") | not)' >/dev/null
}

@test "--dry-run --json reports mode n/a" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"

  run env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json

  echo "$output" | jq -e '.mode == "n/a"' >/dev/null
}

@test "--dry-run --json on a real-sized index exits 0 with the full system prompt (argv limit)" {
  stub="$TMP/fake-claude"; stub_dir="$TMP/stubdata"; mkdir -p "$stub_dir"; make_stub "$stub"
  index_dir="$TMP/index-dir"; mkdir -p "$index_dir"
  # A real index is ~234 KB; the system prompt must not ride in one jq argv.
  awk 'BEGIN { for (i = 1; i <= 3000; i++) printf "%d :: some description text for record number %d that pads the line out\n", i, i }' > "$index_dir/index.txt"
  [ "$(wc -c < "$index_dir/index.txt")" -gt 200000 ]
  last_line="$(tail -n 1 "$index_dir/index.txt")"

  run --separate-stderr env HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  echo "$output" | jq -e --arg last "$last_line" '.stage1_system_prompt | contains($last)' >/dev/null
  echo "$output" | jq -e '.mode == "n/a"' >/dev/null
}

# An empty index selects nothing and would print a confident NOT FOUND — the
# same symptom class as issue #198 — so the script must refuse it.
empty_index_fixture() {
  fresh_fixture
  : > "$index_dir/index.txt"
}

@test "an empty index.txt aborts the run: exit 1, stderr says empty, zero CLI calls, no NOT FOUND" {
  empty_index_fixture

  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"empty"* ]]
  [[ "$output" != *"NOT FOUND"* ]]
  [ ! -f "$stub_dir/count" ]
}

@test "--dry-run on an empty index.txt aborts the same way" {
  empty_index_fixture

  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"empty"* ]]
  [[ "$output" != *"NOT FOUND"* ]]
  [ ! -f "$stub_dir/count" ]
}

# ---------- (h) session-free stage 1: system-prompt file, no resume, no session state ----------
#
# Issue #198. Stage 1 used to --resume a stored session primed with the index,
# so a rewriting proxy could compact that history and the selector collapsed
# to false NOT FOUNDs. Now the select instruction + index ride in a
# --system-prompt-file and the question is the only user message; nothing is
# resumed and no session state is written. fresh_fixture / run_howdoi_ok are the
# shared arrangement for sections (h)-(i); TMPDIR is pinned per test so the
# work dir the script creates is observable (and its removal checkable).

fresh_fixture() {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  work_tmp="$TMP/work-tmp"
  index_dir="$TMP/index-dir"
  mkdir -p "$stub_dir" "$work_tmp" "$index_dir"
  make_stub "$stub"
  printf '1 :: widget record\n2 :: gadget record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n2\tid-two\tpath/two\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"
}

# Runs the script against the fixture; extra args go through, QUESTION overrides "q".
run_howdoi() {
  run env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "${QUESTION:-q}" --index-dir "$index_dir" "$@"
}

# Success-path variant: also asserts the run exited 0, so a script that dies
# early cannot satisfy the artifact checks that follow.
run_howdoi_ok() {
  run_howdoi "$@"
  [ "$status" -eq 0 ]
}

# A bare `! grep` also passes when the file is missing (grep exits 2), so
# require a non-empty file before claiming the pattern is absent from it.
refute_in_file() {
  local pattern="$1" file="$2"
  [ -s "$file" ] || return 1
  if grep -q -- "$pattern" "$file"; then return 1; fi
}

@test "stage 1 never carries --resume, even with a legacy session.id in the index dir" {
  fresh_fixture
  echo "legacy-session-id" > "$index_dir/session.id"
  echo "legacy-fp" > "$index_dir/session.fingerprint"
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  refute_in_file '--resume' "$stub_dir/call-1.args"
  # The legacy id itself must not leak into the args either.
  refute_in_file 'legacy-session-id' "$stub_dir/call-1.args"
}

@test "stage 1 passes --system-prompt-file" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  grep -q -- '^--system-prompt-file$' "$stub_dir/call-1.args"
}

@test "stage 1 passes --no-session-persistence" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  grep -q -- '^--no-session-persistence$' "$stub_dir/call-1.args"
}

@test "the system prompt file holds the select instruction" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  grep -q "choosing which records from an index are relevant" "$stub_dir/call-1.system"
}

@test "the system prompt file holds the Index: header" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  grep -q "^Index:$" "$stub_dir/call-1.system"
}

@test "the system prompt file holds every line of index.txt" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  # index.txt's lines appear verbatim, in order, as the tail of the file.
  tail -n 2 "$stub_dir/call-1.system" | diff - "$index_dir/index.txt"
}

@test "stage 1 stdin is the question" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  QUESTION="how do widgets work" run_howdoi_ok

  [ "$(cat "$stub_dir/call-1.stdin")" = "$(printf 'Question:\nhow do widgets work')" ]
}

@test "stage 1 stdin carries no Index: block" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  refute_in_file "Index:" "$stub_dir/call-1.stdin"
}

@test "stage 1 stdin carries no index content" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  refute_in_file "widget record" "$stub_dir/call-1.stdin"
}

@test "two consecutive runs with an unchanged index send byte-identical system prompt files" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  QUESTION="first question" run_howdoi_ok
  QUESTION="a different question" run_howdoi_ok

  cmp "$stub_dir/call-1.system" "$stub_dir/call-2.system"
}

@test "the second of two consecutive runs does not carry --resume" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  run_howdoi_ok
  run_howdoi_ok

  refute_in_file '--resume' "$stub_dir/call-2.args"
}

@test "no call ever carries --resume, across a stage-1 retry" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "I need to read this carefully."}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  run_howdoi

  # Both attempts must have run, or the glob could match nothing.
  [ -s "$stub_dir/call-1.args" ]
  [ -s "$stub_dir/call-2.args" ]
  for f in "$stub_dir"/call-*.args; do refute_in_file '--resume' "$f"; done
}

@test "on attempt 2 the retry reminder is appended to stdin" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "I need to read this carefully."}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  run_howdoi

  grep -q "Reminder: reply with ONLY a JSON array of integers" "$stub_dir/call-2.stdin"
}

@test "on attempt 2 stdin still starts with the question" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "I need to read this carefully."}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  QUESTION="how do widgets work" run_howdoi

  [ "$(head -n 2 "$stub_dir/call-2.stdin")" = "$(printf 'Question:\nhow do widgets work')" ]
}

@test "on attempt 2 the system prompt file is byte-identical to attempt 1" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "I need to read this carefully."}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  run_howdoi

  cmp "$stub_dir/call-1.system" "$stub_dir/call-2.system"
}

@test "on attempt 2 the system prompt path is the same as attempt 1" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "I need to read this carefully."}' > "$stub_dir/resp-1.json"
  cp "$stub_dir/resp-1.json" "$stub_dir/resp-2.json"

  run_howdoi

  path1="$(grep -A1 -- '^--system-prompt-file$' "$stub_dir/call-1.args" | tail -n 1)"
  path2="$(grep -A1 -- '^--system-prompt-file$' "$stub_dir/call-2.args" | tail -n 1)"
  [ -n "$path1" ]
  [ "$path1" = "$path2" ]
}

@test "the CLI is called with CLAUDE_CODE_DISABLE_CLAUDE_MDS=1" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  # Caller exports 0 so only the script itself can make the CLI see 1.
  CLAUDE_CODE_DISABLE_CLAUDE_MDS=0 run_howdoi_ok

  [ "$(cat "$stub_dir/call-1.env")" = "1" ]
}

@test "a legacy session.id is deleted on a normal run" {
  fresh_fixture
  echo "legacy-session-id" > "$index_dir/session.id"
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  [ ! -e "$index_dir/session.id" ]
}

@test "a legacy session.fingerprint is deleted on a normal run" {
  fresh_fixture
  echo "legacy-fp" > "$index_dir/session.fingerprint"
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  [ ! -e "$index_dir/session.fingerprint" ]
}

@test "a legacy session.id is deleted on a --rebuild run" {
  fresh_fixture
  echo "legacy-session-id" > "$index_dir/session.id"
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"
  scripts_dir="$TMP/scripts"
  make_build_sentinel_scripts_dir "$scripts_dir" "$TMP/build.log"

  run env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir" --rebuild
  [ "$status" -eq 0 ]

  [ ! -e "$index_dir/session.id" ]
}

@test "a legacy session.fingerprint is deleted on a --rebuild run" {
  fresh_fixture
  echo "legacy-fp" > "$index_dir/session.fingerprint"
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"
  scripts_dir="$TMP/scripts"
  make_build_sentinel_scripts_dir "$scripts_dir" "$TMP/build.log"

  run env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir" --rebuild
  [ "$status" -eq 0 ]

  [ ! -e "$index_dir/session.fingerprint" ]
}

@test "--dry-run leaves a legacy session.id in place" {
  fresh_fixture
  echo "legacy-session-id" > "$index_dir/session.id"
  echo "legacy-fp" > "$index_dir/session.fingerprint"

  run_howdoi_ok --dry-run

  [ "$(cat "$index_dir/session.id")" = "legacy-session-id" ]
}

@test "--dry-run leaves a legacy session.fingerprint in place" {
  fresh_fixture
  echo "legacy-session-id" > "$index_dir/session.id"
  echo "legacy-fp" > "$index_dir/session.fingerprint"

  run_howdoi_ok --dry-run

  [ "$(cat "$index_dir/session.fingerprint")" = "legacy-fp" ]
}

# ---------- (i) --timing and --json report mode n/a ----------

@test "--timing prints a stage=select line labeled mode=n/a" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]", duration_ms: 900, duration_api_ms: 300, usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 500}}' > "$stub_dir/resp-1.json"

  run_howdoi_ok --timing

  [[ "$output" == *"[how-do-i timing] stage=select attempt=1 mode=n/a"* ]]
}

@test "--json reports stages.select.mode as n/a" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]", duration_ms: 400, duration_api_ms: 150, usage: {input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}' > "$stub_dir/resp-1.json"

  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir" --json
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.stages.select.mode == "n/a"' >/dev/null
}

@test "--help output names none of session.id, session.fingerprint, warm, --resume" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  ! grep -qE 'session\.id|session\.fingerprint|warm|--resume' <<<"$output"
}

@test "the header comment names none of session.id, session.fingerprint, warm, --resume" {
  header="$(sed '/^set -uo pipefail/q' "$SCRIPT")"
  [ -n "$header" ]

  ! grep -qE 'session\.id|session\.fingerprint|warm|--resume' <<<"$header"
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

@test "an unresolvable claude binary aborts loudly" {
  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: some record\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  seed_roots_stamp "$index_dir"
  nonexistent="$TMP/does-not-exist/claude"

  run env HOWDOI_CLAUDE_BIN="$nonexistent" bash "$SCRIPT" --question "q" --index-dir "$index_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
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

  # Isolate CLAUDE_CONFIG_DIR so we don't pick up ~/.claude/settings.json
  isolated_config="$TMP/isolated-config"
  mkdir -p "$isolated_config"

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

  run env CLAUDE_CONFIG_DIR="$isolated_config" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
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

  # Isolate CLAUDE_CONFIG_DIR so we don't pick up ~/.claude/settings.json
  isolated_config="$TMP/isolated-config"
  mkdir -p "$isolated_config"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: fresh content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  touch -t 202501010000 "$index_dir/index.txt"
  CLAUDE_CONFIG_DIR="$isolated_config" seed_roots_stamp "$index_dir"

  # A record file that predates the index — must NOT trigger a rebuild.
  printf '# old record\n' > "$CODEX_ROOT/old.md"
  touch -t 202001010000 "$CODEX_ROOT/old.md"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env CLAUDE_CONFIG_DIR="$isolated_config" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ ! -f "$build_log" ]
  grep -q "fresh content" "$index_dir/index.txt"
}

# Regression: a long-lived session (or an out-of-session shell) started
# before CODEX_STORE_ROOTS was added to settings.json's `env` block has
# neither CODEX_STORE_ROOTS nor CODEX_ROOT in its process env. Before the
# settings.json fallback, CURRENT_ROOTS silently collapsed to the hardcoded
# ~/.claude default in that case, and — because roots.stamp then recorded
# THAT (wrong) value — never self-repaired on a later run either.
@test "CODEX_STORE_ROOTS and CODEX_ROOT both unset: roots resolve from this process's settings.json" {
  unset CODEX_ROOT
  unset CODEX_STORE_ROOTS

  fake_config="$TMP/fake-config"
  mkdir -p "$fake_config"
  settings_root="$TMP/from-settings-root"
  mkdir -p "$settings_root"
  jq -n --arg r "$settings_root" '{env: {CODEX_STORE_ROOTS: $r}}' > "$fake_config/settings.json"

  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  # No pre-seeded index/stamp: forces a build, which is what observes
  # CURRENT_ROOTS.

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env CLAUDE_CONFIG_DIR="$fake_config" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ -f "$build_log" ]
  [ "$(sed -n '1p' "$index_dir/roots.stamp")" = "$settings_root" ]
}

@test "CODEX_ROOT set AND settings.json present: settings.json wins over CODEX_ROOT" {
  fake_config="$TMP/fake-config"
  mkdir -p "$fake_config"
  settings_root="$TMP/from-settings-root"
  mkdir -p "$settings_root"
  jq -n --arg r "$settings_root" '{env: {CODEX_STORE_ROOTS: $r}}' > "$fake_config/settings.json"

  unset CODEX_STORE_ROOTS
  export CODEX_ROOT="$TMP/legacy-root"
  mkdir -p "$CODEX_ROOT"

  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  index_dir="$TMP/index-dir"
  # No pre-seeded index/stamp: forces a build, which observes CURRENT_ROOTS.

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env CLAUDE_CONFIG_DIR="$fake_config" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ -f "$build_log" ]
  # settings.json root should win, not the CODEX_ROOT
  [ "$(sed -n '1p' "$index_dir/roots.stamp")" = "$settings_root" ]
}

@test "a rebuild forced by the mtime trigger rewrites roots.stamp with the roots actually used" {
  stub="$TMP/fake-claude"
  stub_dir="$TMP/stubdata"
  mkdir -p "$stub_dir"
  make_stub "$stub"

  # Isolate CLAUDE_CONFIG_DIR so we don't pick up ~/.claude/settings.json
  isolated_config="$TMP/isolated-config"
  mkdir -p "$isolated_config"

  index_dir="$TMP/index-dir"
  mkdir -p "$index_dir"
  printf '1 :: stale content\n' > "$index_dir/index.txt"
  printf '1\tid-one\tpath/one\n' > "$index_dir/map.tsv"
  touch -t 202001010000 "$index_dir/index.txt"
  CLAUDE_CONFIG_DIR="$isolated_config" seed_roots_stamp "$index_dir"

  # A record file that changed after the index was built — triggers the
  # mtime rebuild path (not the roots-mismatch path, since the stamp already
  # matches CURRENT_ROOTS).
  printf '# changed record\n' > "$CODEX_ROOT/changed.md"
  touch -t 202501010000 "$CODEX_ROOT/changed.md"

  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  scripts_dir="$TMP/scripts"
  build_log="$TMP/build.log"
  make_build_sentinel_scripts_dir "$scripts_dir" "$build_log"

  run env CLAUDE_CONFIG_DIR="$isolated_config" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 0 ]
  [ -f "$build_log" ]
  grep -q "rebuilt content" "$index_dir/index.txt"
  # roots.stamp was rewritten recording the roots this rebuild actually
  # used (a same-second rewrite can coincidentally match stamp_before
  # byte-for-byte, so this pins content correctness, not just "changed").
  [ "$(sed -n '1p' "$index_dir/roots.stamp")" = "$CODEX_ROOT" ]
  [ -f "$index_dir/roots.stamp" ]
}

# ---------- (p) failure modes and leftovers (issue #198) ----------

@test "a non-zero stage-1 CLI exit fails the run with exit 1" {
  fresh_fixture
  echo 3 > "$stub_dir/exit-1"
  # A rejected call has no JSON on stdout; the CLI's complaint is on stderr.

  run_howdoi

  [ "$status" -eq 1 ]
}

@test "a non-zero stage-1 CLI exit surfaces the CLI's stderr text on stderr" {
  fresh_fixture
  echo 3 > "$stub_dir/exit-1"
  echo "boom: unknown flag --system-prompt-file" > "$stub_dir/stderr-1"

  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [[ "$stderr" == *"boom: unknown flag --system-prompt-file"* ]]
}

@test "a non-zero stage-1 CLI exit never prints NOT FOUND on stdout" {
  fresh_fixture
  echo 3 > "$stub_dir/exit-1"

  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [[ "$output" != *"NOT FOUND"* ]]
}

# Builds a bin dir with a failing fake `claude` and a failing fake `orwrap`.
# Each appends one line (its name and argv) to $2 per call, so call count and
# the --system-prompt-file path of each call are observable.
make_failing_gateway_bin() {
  local bin="$1" log="$2" name
  mkdir -p "$bin"
  for name in claude orwrap; do
    cat > "$bin/$name" <<GATEWAY
#!/usr/bin/env bash
echo "$name \$*" >> "$log"
cat > /dev/null
echo "boom from $name" >&2
exit 1
GATEWAY
    chmod +x "$bin/$name"
  done
}

@test "with orwrap on PATH and raw claude failing, the run exits 1 after exactly 2 calls" {
  fresh_fixture
  bin="$TMP/bin"; log="$TMP/spawn.log"
  make_failing_gateway_bin "$bin" "$log"

  run env TMPDIR="$work_tmp" PATH="$bin:$PATH" HOWDOI_CLAUDE_BIN= bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [ "$status" -eq 1 ]
  [ "$(wc -l < "$log")" -eq 2 ]
}

@test "the orwrap retry reuses the same --system-prompt-file path as the raw call" {
  fresh_fixture
  bin="$TMP/bin"; log="$TMP/spawn.log"
  make_failing_gateway_bin "$bin" "$log"

  run env TMPDIR="$work_tmp" PATH="$bin:$PATH" HOWDOI_CLAUDE_BIN= bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  path1="$(sed -n '1p' "$log" | tr ' ' '\n' | grep -A1 -- '^--system-prompt-file$' | tail -n 1)"
  path2="$(sed -n '2p' "$log" | tr ' ' '\n' | grep -A1 -- '^--system-prompt-file$' | tail -n 1)"
  [ -n "$path1" ]
  [ "$path1" = "$path2" ]
}

@test "the second failing call goes through orwrap claude" {
  fresh_fixture
  bin="$TMP/bin"; log="$TMP/spawn.log"
  make_failing_gateway_bin "$bin" "$log"

  run env TMPDIR="$work_tmp" PATH="$bin:$PATH" HOWDOI_CLAUDE_BIN= bash "$SCRIPT" --question "q" --index-dir "$index_dir"

  [[ "$(sed -n '2p' "$log")" == "orwrap claude "* ]]
}

@test "a null structured_output reply on call 1: call 1 carries --json-schema" {
  fresh_fixture
  jq -n '{is_error: false, structured_output: null, result: "null", session_id: "s"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s", result: "[]"}' > "$stub_dir/resp-2.json"

  run_howdoi_ok

  grep -q -- '^--json-schema$' "$stub_dir/call-1.args"
}

@test "a null structured_output reply on call 1: call 2 drops --json-schema" {
  fresh_fixture
  jq -n '{is_error: false, structured_output: null, result: "null", session_id: "s"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s", result: "[]"}' > "$stub_dir/resp-2.json"

  run_howdoi_ok

  refute_in_file '^--json-schema$' "$stub_dir/call-2.args"
}

@test "a null structured_output reply: both calls carry --system-prompt-file" {
  fresh_fixture
  jq -n '{is_error: false, structured_output: null, result: "null", session_id: "s"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s", result: "[]"}' > "$stub_dir/resp-2.json"

  run_howdoi_ok

  [ "$(grep -l -- '^--system-prompt-file$' "$stub_dir"/call-1.args "$stub_dir"/call-2.args | wc -l)" -eq 2 ]
}

@test "stage 2 carries --no-session-persistence" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[2]"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s2", result: "The answer."}' > "$stub_dir/resp-2.json"
  scripts_dir="$TMP/scripts"
  make_sentinel_scripts_dir "$scripts_dir" "$TMP/compile.log"

  run env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"
  [ "$status" -eq 0 ]

  grep -q -- '^--no-session-persistence$' "$stub_dir/call-2.args"
}

@test "stage 2 never carries --resume" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[2]"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, session_id: "s2", result: "The answer."}' > "$stub_dir/resp-2.json"
  scripts_dir="$TMP/scripts"
  make_sentinel_scripts_dir "$scripts_dir" "$TMP/compile.log"

  run env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$scripts_dir/how-do-i.sh" --question "q" --index-dir "$index_dir"
  [ "$status" -eq 0 ]

  refute_in_file '--resume' "$stub_dir/call-2.args"
}

@test "a successful run leaves no how-do-i.* work dir under TMPDIR" {
  fresh_fixture
  jq -n '{is_error: false, session_id: "s1", result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_ok

  # The stub ran, so the script got past mktemp and the cleanup is real.
  [ -s "$stub_dir/call-1.args" ]
  [ -z "$(ls -d "$work_tmp"/how-do-i.* 2>/dev/null)" ]
}

@test "a failed run leaves no how-do-i.* work dir under TMPDIR" {
  fresh_fixture
  echo 3 > "$stub_dir/exit-1"

  run_howdoi
  [ "$status" -eq 1 ]

  [ -s "$stub_dir/call-1.args" ]
  [ -z "$(ls -d "$work_tmp"/how-do-i.* 2>/dev/null)" ]
}

# ---------- (q) index guard: a usable index holds a record line; --dry-run leaves nothing behind (issue #231) ----------
#
# A usable index is readable AND holds at least one line shaped "<digits> :: ".
# A whitespace-only or junk index used to pass the old size-only check and ended
# as a confident NOT FOUND from a stage-1 call that never saw a record. The hint
# differs by mode: a --dry-run user must re-run WITHOUT --dry-run and WITH
# --rebuild (a run without --dry-run reuses a bad index, a bare --rebuild next to
# --dry-run is a usage error). --dry-run --json also makes no temp file, so a
# signal mid-render cannot leak one. Fixtures reuse fresh_fixture; the index is
# overwritten per test and the stub must stay uncalled on every refused run.

# run_howdoi with stderr split out, so a test can assert on the message text.
run_howdoi_split() {
  run --separate-stderr env TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir" "$@"
}

# One record in a temp CODEX_ROOT so build-record-index.sh succeeds for real. The
# record is backdated so the existing index is reused (not rebuilt) until a
# --rebuild asks for it.
rebuildable_root_fixture() {
  mkdir -p "$CODEX_ROOT/records/decisions"
  printf -- '---\nid: rec-one\ndescription: a widget record\n---\nbody\n' > "$CODEX_ROOT/records/decisions/one.md"
  touch -t 202001010000 "$CODEX_ROOT/records/decisions/one.md"
}

# The three shapes the guard refuses besides a zero-byte file; the third has
# non-whitespace text but no "<digits> :: " line.
set_bad_index() {
  case "$1" in
    zero)       : > "$index_dir/index.txt" ;;
    whitespace) printf ' \t\n\n  \n' > "$index_dir/index.txt" ;;
    html)       printf '<html>502 Bad Gateway</html>\n' > "$index_dir/index.txt" ;;
    lead-space) printf ' 1 :: x\n' > "$index_dir/index.txt" ;;
    no-space)   printf '1::x\n' > "$index_dir/index.txt" ;;
  esac
}

# Refusal contract shared by AC1-AC3: exit 1, "no record" on stderr, no NOT FOUND, stub never called.
assert_refused() {
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no record"* ]]
  [[ "$output" != *"NOT FOUND"* ]]
  [ ! -f "$stub_dir/count" ]
}

@test "a whitespace-only index.txt aborts a real run: exit 1, no record on stderr, zero CLI calls, no NOT FOUND" {
  fresh_fixture
  set_bad_index whitespace

  run_howdoi_split

  assert_refused
}

@test "a whitespace-only index.txt aborts --dry-run: exit 1, no record on stderr, empty stdout" {
  fresh_fixture
  set_bad_index whitespace

  run_howdoi_split --dry-run

  assert_refused
  [ -z "$output" ]
}

@test "an index.txt with no record line (HTML error page) is refused with and without --dry-run" {
  fresh_fixture
  set_bad_index html

  run_howdoi_split
  assert_refused
  run_howdoi_split --dry-run
  assert_refused
}

@test "an index.txt whose only line starts with a space is refused with and without --dry-run" {
  fresh_fixture
  set_bad_index lead-space

  run_howdoi_split
  assert_refused
  run_howdoi_split --dry-run
  assert_refused
}

@test "an index.txt whose only line has no spaces around :: is refused with and without --dry-run" {
  fresh_fixture
  set_bad_index no-space

  run_howdoi_split
  assert_refused
  run_howdoi_split --dry-run
  assert_refused
}

@test "--dry-run on a bad index names one full next step: without --dry-run and with --rebuild" {
  fresh_fixture

  for shape in zero whitespace html; do
    set_bad_index "$shape"
    run_howdoi_split --dry-run
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"without --dry-run and with --rebuild"* ]]
    # The old one-clause hint told a dry-run user to add --rebuild to the same command.
    [[ "$stderr" != *"re-run with --rebuild"* ]]
  done
}

@test "following the --dry-run hint rebuilds the index and answers" {
  fresh_fixture
  rebuildable_root_fixture
  set_bad_index whitespace
  jq -n '{is_error: false, result: "[]"}' > "$stub_dir/resp-1.json"

  run_howdoi_split --dry-run
  [ "$status" -eq 1 ]
  # The step the hint names: the same command minus --dry-run, plus --rebuild.
  run_howdoi_split --rebuild

  [ "$status" -eq 0 ]
  grep -qE '^[0-9]+ :: ' "$index_dir/index.txt"
  [ -s "$stub_dir/call-1.args" ]
}

@test "a bad index without --dry-run exits 1 and the hint names --rebuild" {
  fresh_fixture

  for shape in zero whitespace html; do
    set_bad_index "$shape"
    run_howdoi_split
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"--rebuild"* ]]
  done
}

@test "a bad index without --dry-run is repaired by --rebuild and the stub answer reaches stdout" {
  fresh_fixture
  rebuildable_root_fixture
  set_bad_index whitespace
  jq -n '{is_error: false, result: "[1]"}' > "$stub_dir/resp-1.json"
  jq -n '{is_error: false, result: "the stub answer"}' > "$stub_dir/resp-2.json"

  run_howdoi_split --rebuild

  [ "$status" -eq 0 ]
  grep -qE '^[0-9]+ :: ' "$index_dir/index.txt"
  [[ "$output" == *"the stub answer"* ]]
}

# A jq wrapper that stalls on EVERY call, so a signal can land while the
# --dry-run --json render is in flight. It records its pid (exec keeps it) and a
# "started" marker, waits, then execs the real jq with the same arguments.
make_slow_jq() {
  local dir="$1" real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$dir"
  cat > "$dir/jq" <<WRAP
#!/usr/bin/env bash
echo \$\$ > "$dir/pid"
: > "$dir/started"
sleep 2
exec "$real_jq" "\$@"
WRAP
  chmod +x "$dir/jq"
}

# Starts the --dry-run --json render behind the slow jq, waits (bounded) for the
# wrapper to start, sends signal $1 to the script, then waits for it and for the
# wrapper child. Sets sig_status; stdout lands in $TMP/sig.out.
dry_json_signalled() {
  local sig="$1" pid i
  fresh_fixture
  make_slow_jq "$TMP/slow-jq"
  ( export PATH="$TMP/slow-jq:$PATH" TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir"
    exec bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json ) \
    > "$TMP/sig.out" 2> "$TMP/sig.err" 3>&- &
  pid=$!
  for i in $(seq 1 100); do [ -e "$TMP/slow-jq/started" ] && break; sleep 0.1; done
  [ -e "$TMP/slow-jq/started" ]
  kill -"$sig" "$pid"
  sig_status=0
  wait "$pid" || sig_status=$?
  # The wrapper child may outlive the script; wait (max 10 s) until it has exited.
  for i in $(seq 1 100); do kill -0 "$(cat "$TMP/slow-jq/pid")" 2>/dev/null || break; sleep 0.1; done
}

@test "SIGTERM during --dry-run --json exits 143, prints no complete JSON and leaves no how-do-i entry in TMPDIR" {
  dry_json_signalled TERM

  [ "$sig_status" -eq 143 ]
  # Slurped: jq 1.6 exits 0 for `-e` on empty input, so a bare `-e` filter reads an empty stdout as an object.
  if jq -es 'length > 0 and (.[0] | type == "object")' "$TMP/sig.out" >/dev/null 2>&1; then return 1; fi
  [ -z "$(ls -A "$work_tmp" | grep '^how-do-i')" ]
}

@test "SIGHUP during --dry-run --json exits 129, prints no complete JSON and leaves no how-do-i entry in TMPDIR" {
  dry_json_signalled HUP

  [ "$sig_status" -eq 129 ]
  # Slurped: jq 1.6 exits 0 for `-e` on empty input, so a bare `-e` filter reads an empty stdout as an object.
  if jq -es 'length > 0 and (.[0] | type == "object")' "$TMP/sig.out" >/dev/null 2>&1; then return 1; fi
  [ -z "$(ls -A "$work_tmp" | grep '^how-do-i')" ]
}

@test "a failing jq render under --dry-run --json exits 1 with empty stdout, could not render on stderr and no how-do-i entry in TMPDIR" {
  fresh_fixture
  mkdir -p "$TMP/bad-jq"
  # Prints a complete object, THEN fails: a script that forwards partial output leaks it.
  printf '#!/bin/sh\necho "{\\"stage1_system_prompt\\":\\"x\\"}"\nexit 1\n' > "$TMP/bad-jq/jq"
  chmod +x "$TMP/bad-jq/jq"

  run --separate-stderr env PATH="$TMP/bad-jq:$PATH" TMPDIR="$work_tmp" HOWDOI_CLAUDE_BIN="$stub" STUB_DIR="$stub_dir" \
      bash "$SCRIPT" --question "q" --index-dir "$index_dir" --dry-run --json

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"could not render"* ]]
  [ -z "$(ls -A "$work_tmp")" ]
}

@test "a normal --dry-run leaves no how-do-i entry in TMPDIR" {
  fresh_fixture

  run_howdoi_ok --dry-run

  [ -z "$(ls -A "$work_tmp")" ]
}

@test "a normal --dry-run --json leaves no how-do-i entry in TMPDIR" {
  fresh_fixture

  run_howdoi_ok --dry-run --json

  [ -z "$(ls -A "$work_tmp")" ]
}

# Runs the same index through a real stage-1 call and --dry-run --json, then
# compares the system prompt byte for byte (the stub copies the real file at
# call time). jq -j writes the string raw, with no added newline.
assert_dry_json_matches_real_call() {
  jq -n '{is_error: false, result: "[]"}' > "$stub_dir/resp-1.json"
  run_howdoi_ok
  [ -s "$stub_dir/call-1.system" ]
  run_howdoi_ok --dry-run --json
  printf '%s' "$output" | jq -j '.stage1_system_prompt' > "$TMP/dry.system"
  cmp "$TMP/dry.system" "$stub_dir/call-1.system"
}

# One index line over 4096 bytes of a 3-byte character, after $1 ASCII bytes.
wide_char_index() {
  local pad="$1" dash line="" i
  dash="$(printf '\xe2\x80\x94')"
  for ((i = 0; i < 1500; i++)); do line+="$dash"; done
  printf '1 :: %s%s\n2 :: tail record\n' "$(printf '%*s' "$pad" '' | tr ' ' a)" "$line" > "$index_dir/index.txt"
}

@test "--dry-run --json system prompt is byte-equal to the real call on a 3000-line index" {
  fresh_fixture
  awk 'BEGIN { for (i = 1; i <= 3000; i++) printf "%d :: some description text for record number %d that pads the line out\n", i, i }' > "$index_dir/index.txt"

  assert_dry_json_matches_real_call
}

@test "--dry-run --json system prompt is byte-equal to the real call on a 4 KB multibyte line, offset 0" {
  fresh_fixture
  wide_char_index 0

  assert_dry_json_matches_real_call
}

@test "--dry-run --json system prompt is byte-equal to the real call on a 4 KB multibyte line, offset 1" {
  fresh_fixture
  wide_char_index 1

  assert_dry_json_matches_real_call
}

@test "--dry-run --json system prompt is byte-equal to the real call on a 4 KB multibyte line, offset 2" {
  fresh_fixture
  wide_char_index 2

  assert_dry_json_matches_real_call
}

# Accepted shapes: --dry-run exits 0 and prints the record line. $1 is the
# printf body written to index.txt, $2 the text the output must carry.
assert_dry_accepts() {
  printf "$1" > "$index_dir/index.txt"
  run_howdoi_split --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"$2"* ]]
}

@test "an index with one record line between blank lines is accepted" {
  fresh_fixture
  assert_dry_accepts '\n\n1 :: only record\n\n' '1 :: only record'
}

@test "an index whose description holds :: is accepted" {
  fresh_fixture
  assert_dry_accepts '1 :: a :: b\n' '1 :: a :: b'
}

@test "an index with an empty description is accepted" {
  fresh_fixture
  assert_dry_accepts '1 :: \n' '1 :: '
}

@test "an index with CRLF line ends is accepted" {
  fresh_fixture
  assert_dry_accepts '1 :: crlf record\r\n2 :: second\r\n' '1 :: crlf record'
}

@test "an index with one record line plus junk lines is accepted" {
  fresh_fixture
  assert_dry_accepts 'junk\n<html>\n1 :: kept record\nmore junk\n' '1 :: kept record'
}

@test "no file under plugins/procedures holds the old size-only guard message" {
  # Built in two halves so this file does not match its own grep.
  old="missing, unreadable or"" empty"

  run grep -rnF -- "$old" "$BATS_TEST_DIRNAME/../.."

  [ -z "$output" ]
}

@test "neither the script nor the skills tell a --dry-run user to put --rebuild on the same command" {
  run grep -rnE -- '--dry-run +--rebuild|--rebuild +--dry-run' \
      "$SCRIPT" "$BATS_TEST_DIRNAME/../../skills"

  [ -z "$output" ]
}

@test "--help tells a --dry-run user to re-run without --dry-run and with --rebuild" {
  run bash "$SCRIPT" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"without --dry-run and with --rebuild"* ]]
}
