#!/usr/bin/env bash
# how-do-i.sh — end-to-end driver for /how-do-i: question -> stage 1 (fast
# model + numbered index -> JSON array of numbers) -> compile -> stage 2
# (strong model + compiled records -> answer).
#
# A script, not a subagent fork, on purpose: process lifecycle, prompt
# caching, and the output contract all need direct control.
#
# Measured facts this script is built around (see the how-do-i research/
# probe history for the raw numbers, not repeated here):
#   - Inference is a small slice of wall time; process spawn/teardown + CLI
#     boot dominate, and are paid ONCE PER STAGE. --timing below reports
#     wall_ms (whole subprocess) split into cli_overhead_ms (CLI-internal:
#     boot + response handling, not separable further from the CLI's own
#     JSON) + api_ms (the model call itself) + spawn_teardown_ms (process
#     overhead outside the CLI's own timer). The three sum to wall_ms, except
#     that cli_overhead_ms/spawn_teardown_ms are floored at 0 — millisecond-
#     boundary rounding between bash's timer and the CLI's own can otherwise
#     surface as a nonsensical negative "overhead" or "teardown" duration.
#   - MAX_THINKING_TOKENS=0 is exported for both stages: the single biggest
#     inference-latency lever measured.
#   - Prompt-cache session reuse is a big COST win, a small WALL win (every
#     --resume still pays process spawn). See CACHING below.
#   - Cold-start wall time varies a lot run to run, so every timing this
#     script reports is labeled cold or warm — never presented bare.
#
# Pipeline:
#   1. Resolve/build the record index (build-record-index.sh --out DIR).
#      Invalidation: a roots.stamp next to index.txt records the roots
#      string the index was built from. A rebuild is forced by --rebuild, a
#      missing index/map/stamp, a roots.stamp that no longer matches the
#      current CODEX_STORE_ROOTS/CODEX_ROOT resolution, or any *.md under
#      those roots newer than index.txt — otherwise the existing index is
#      reused as-is.
#   2. Stage 1 (select): fast model + full index (cold) or a resumed session
#      (warm) -> JSON array of selected record numbers.
#   3. compile-records.sh turns the selected numbers into record text.
#      An EMPTY selection short-circuits here: stage 1 saying "nothing is
#      relevant" is an answer, so the run prints NOT FOUND and exits 0
#      rather than handing compile-records.sh a selection it must reject.
#   4. Stage 2 (answer): strong model + compiled records -> the answer.
#
# CACHING: priming (cold) call's session_id is captured from the response
# JSON and persisted at DIR/session.id, alongside a checksum of index.txt at
# DIR/session.fingerprint. A later run recomputes the checksum: if it
# matches, stage 1 resumes the stored session (warm, short prompt); if it
# differs or either file is missing, stage 1 primes fresh (cold, full
# prompt) and — only on success — overwrites both files. This never serves
# an answer from a session primed on a stale index.
#
# Usage:
#   how-do-i.sh [--question TEXT | --question-file PATH] [--index-dir DIR]
#               [--rebuild] [--select-model haiku] [--answer-model sonnet]
#               [--expand-links] [--json] [--dry-run] [--timing]
#
# See --help for the full flag reference.
#
# Env:
#   HOWDOI_CLAUDE_BIN   override for the `claude` binary. Tests point this
#                       at a fixture stub so no real model is ever called by
#                       the test suite. Default: claude (resolved via PATH).
#   HOWDOI_INDEX_DIR    default for --index-dir when the flag is omitted.
#                       Default: $(procedures_state_dir)/how-do-i-index — i.e.
#                       ~/.knowledge/state/how-do-i-index when ~/.knowledge exists,
#                       else the XDG state-dir fallback (see lib/stores.sh
#                       procedures_state_dir).
#   CODEX_STORE_ROOTS   colon-separated record-store roots (see lib/stores.sh
#                       _stores_resolve_roots_spec) — drives cache
#                       invalidation (above) as well as what
#                       build-record-index.sh itself scans.
#   CODEX_ROOT          single-root fallback when CODEX_STORE_ROOTS is unset.
#                       Resolution order when both are unset: this process's
#                       own settings.json (.env.CODEX_STORE_ROOTS, at
#                       ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json),
#                       then hardcoded ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
#
# Output:
#   Default    the stage-2 answer on stdout, nothing else. On an empty
#              selection, a NOT FOUND message instead (exit 0).
#   --json     a JSON object: answer, selected_numbers, resolved_ids,
#              stages.{select,answer} (model, mode, attempts, wall_ms,
#              cli_duration_ms, api_ms, usage incl. cache read/creation).
#              On an empty selection it additionally carries not_found:true,
#              with empty selection arrays and stages.answer null (stage 2
#              never ran). not_found is ABSENT on every other outcome.
#   --timing   a stderr breakdown per stage/attempt: wall/boot/api/cache_*,
#              always labeled mode=cold|warm|n/a. No-op under --dry-run
#              (nothing was timed).
#   --dry-run  builds and prints the prompt(s) that WOULD be sent; makes NO
#              model calls and requires an index.txt to already exist (it
#              never builds one — see --rebuild below). Stage 2's prompt is
#              necessarily a TEMPLATE: the real one depends on stage 1's
#              live selection, which --dry-run never performs.
#
# Exit codes:
#   0  succeeded (answer printed, NOT FOUND printed on an empty selection,
#      or --dry-run printed its prompts)
#   1  fatal runtime error (binary/script not found, a stage failed or was
#      unparseable after retry, empty output, compile-records.sh failed)
#   2  usage error: unknown/missing/conflicting flags
#
# --rebuild and --dry-run are rejected together (exit 2): --dry-run reads
# an existing index only and never builds one, so the combination can never
# do what it says.
#
# Internal test-support seams (NOT part of the public interface; exercised
# by hooks/tests/how-do-i.bats so the pure-logic pieces — response parsing,
# validation, timing-line formatting — can be unit-tested without a real
# model call or a real compile-records.sh/build-record-index.sh):
#   --internal-parse-selection <file|->   parses a stage-1 CLI response JSON
#                                          (fenced/bare JSON array, or a
#                                          --json-schema structured_output)
#                                          -> "OK <n1> <n2> ..." or
#                                          "FAIL <reason>" (exit 1).
#   --internal-validate-answer <file|->   validates a stage-2 CLI response
#                                          JSON (is_error, non-empty result)
#                                          -> "OK <text>" or "FAIL <reason>"
#                                          (exit 1).
#   --internal-format-timing <label> <attempt> <mode> <wall_seconds> <file>
#                                          -> the exact --timing line for
#                                          one call, from a given response
#                                          JSON file and wall-clock seconds.

set -uo pipefail
# No -e: this script's control flow is retry/branch-heavy (stage 1 can
# retry, either stage can fail in several distinct, distinctly-messaged
# ways). Every risky command's exit status is captured and checked
# explicitly instead, which is easier to reason about here than fighting
# -e's implicit-abort semantics across that many branches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'how-do-i: %s\n' "$1" >&2; exit 1; }

# Single source of truth for "what roots are currently configured" —
# _stores_resolve_roots_spec (lib/stores.sh), the SAME resolver
# build-record-index.sh calls for its own root list, so the stamp written
# below can never drift from what a rebuild actually scans. Sourced HERE,
# high up (before usage() and before INDEX_DIR's default below), not lazily:
# both INDEX_DIR's default — via procedures_state_dir — and CURRENT_ROOTS
# (further down) now depend on this lib being loaded.
STORES_LIB="$SCRIPT_DIR/lib/stores.sh"
[ -f "$STORES_LIB" ] || die "lib/stores.sh not found at $STORES_LIB (expected sibling of build-record-index.sh)"
# shellcheck source=lib/stores.sh
source "$STORES_LIB"

usage() {
    cat <<'EOF'
Usage: how-do-i.sh [--question TEXT | --question-file PATH] [--index-dir DIR]
                    [--rebuild] [--select-model haiku] [--answer-model sonnet]
                    [--expand-links] [--json] [--dry-run] [--timing]

End-to-end driver: question -> stage 1 (fast model + numbered index -> JSON
array of numbers) -> compile-records.sh -> stage 2 (strong model + compiled
records -> answer).

Required (exactly one):
  --question TEXT        the question, given directly.
  --question-file PATH   the question, read from a file.

Options:
  --index-dir DIR    where index.txt/map.tsv/session.id/session.fingerprint
                      live. Default: $HOWDOI_INDEX_DIR or
                      $(procedures_state_dir)/how-do-i-index — i.e.
                      ~/.knowledge/state/how-do-i-index when ~/.knowledge exists,
                      else the XDG state-dir fallback (see lib/stores.sh).
  --rebuild           force a fresh build-record-index.sh run even if an
                      index already exists. Rejected together with
                      --dry-run (exit 2).
  --select-model NAME  model for stage 1. Default: haiku.
  --answer-model NAME  model for stage 2. Default: sonnet.
  --expand-links       passed through to compile-records.sh.
  --json               print a JSON object instead of plain text — see
                      the script header for the exact shape. An empty
                      selection adds not_found:true and exits 0.
  --dry-run            build and print the prompt(s) that would be sent;
                      make no model calls. Requires an existing index.txt
                      (never builds one). Stage 2's prompt is a template.
  --timing             print a per-stage/attempt timing breakdown to
                      stderr, always labeled cold, warm, or n/a.
  --help, -h           show this help and exit 0.

Env:
  HOWDOI_CLAUDE_BIN   override the `claude` binary (tests point this at a
                      stub). Default: claude, resolved via PATH.
  HOWDOI_INDEX_DIR    default for --index-dir. Default:
                      $(procedures_state_dir)/how-do-i-index — i.e.
                      ~/.knowledge/state/how-do-i-index when ~/.knowledge exists,
                      else the XDG state-dir fallback (see lib/stores.sh).

Exit codes: 0 succeeded, 1 fatal runtime error, 2 usage error.
EOF
}

TIMEFORMAT='%R'

# Object-rooted per the Anthropic tool-schema constraint: a bare `array`
# root is rejected by the API (400, "input_schema.type: Input should be
# 'object'"). Wrapping the array as a named property of an object is
# accepted, and additionally makes the CLI populate `.structured_output`.
STAGE1_SCHEMA='{"type":"object","properties":{"selected":{"type":"array","items":{"type":"integer"},"description":"Numbers of the relevant records from the index, most relevant first. Empty array if none are relevant."}},"required":["selected"]}'

SELECT_INSTRUCTION='You are choosing which records from an index are relevant to answering a question. The index has one record per line, formatted "N :: description", where N is the record number.

Reply with a JSON array of the numbers (integers) of the relevant records, most relevant first. If nothing in the index is relevant, reply with an empty JSON array []. Reply with ONLY the JSON array — no prose, no explanation, no markdown formatting.'

ANSWER_INSTRUCTION='Answer the question using ONLY the reference records below. Cite which record(s) you drew from by their id/path. If the records do not contain enough information to answer, say so plainly rather than guessing.'

# --- portable checksum: sha256 preferred, cksum as a last resort ---
compute_fingerprint() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        cksum "$file" | awk '{print $1"-"$2}'
    fi
}

# --- CLI-response JSON accessors. Each is defensive: unparseable/missing
#     input yields a safe default rather than crashing the caller. ---
resp_is_error() {
    jq -r 'if .is_error == true then "true" else "false" end' "$1" 2>/dev/null || echo "true"
}
resp_result_text() {
    jq -r '.result // ""' "$1" 2>/dev/null || echo ""
}
resp_session_id() {
    jq -r '.session_id // ""' "$1" 2>/dev/null || echo ""
}
resp_duration_ms() {
    jq -r '.duration_ms // 0' "$1" 2>/dev/null || echo 0
}
resp_duration_api_ms() {
    jq -r '.duration_api_ms // 0' "$1" 2>/dev/null || echo 0
}
resp_usage_field() {
    jq -r --arg f "$2" '(.usage[$f] // 0)' "$1" 2>/dev/null || echo 0
}

# Parses a stage-1 response file into {ok, reason, numbers}. Prefers
# --json-schema's structured_output when present; otherwise strips a
# fenced code block (```json ... ``` or bare ```...```) from .result and
# parses what remains as either a bare JSON array of numbers or an object
# with a "selected" array (mirrors STAGE1_SCHEMA's shape). Failing both,
# it scavenges the FIRST well-formed JSON array of integers found anywhere
# in the reply: the selector runs on a fast model told to emit only the
# array, which in practice sometimes appends invented explanation after
# it, and requiring the WHOLE reply to be bare JSON turned those replies
# into spurious retry-then-die failures. Scavenging is deliberately LAST
# so it can never pre-empt the object path on a reply that legitimately
# carries {"selected": [...]}. A reply reducing to none of those (prose
# with no array literal) yields ok:false, reason:"unparseable" — the
# caller retries this specific reason once. An is_error response yields
# ok:false, reason:"is_error" — never retried.
parse_selection() {
    jq -c '
        if (.is_error == true) then
            {ok: false, reason: "is_error", numbers: null}
        elif ((.structured_output.selected? // null) != null) then
            (.structured_output.selected) as $n
            | if ($n | type) == "array" and ($n | all(type == "number"))
              then {ok: true, reason: "structured_output", numbers: $n}
              else {ok: false, reason: "structured_output-shape", numbers: null}
              end
        else
            (.result // "") as $r
            | ($r
                | gsub("^\\s*```(json)?\\s*"; "")
                | gsub("\\s*```\\s*$"; "")
                | gsub("^\\s+"; "")
                | gsub("\\s+$"; "")
              ) as $stripped
            | ($stripped | try fromjson catch null) as $parsed
            | if ($parsed != null and ($parsed | type) == "array" and ($parsed | all(type == "number")))
              then {ok: true, reason: "text", numbers: $parsed}
              elif ($parsed != null and ($parsed | type) == "object"
                    and (($parsed.selected? // null) != null)
                    and (($parsed.selected) | type) == "array"
                    and (($parsed.selected) | all(type == "number")))
              then {ok: true, reason: "text-object", numbers: $parsed.selected}
              else
                # Scavenge the first "[...]" holding only integers/commas/
                # whitespace. The pattern admits nothing else, so prose like
                # "[see record 3]" cannot match and stays unparseable.
                # match/1 emits an EMPTY STREAM (not an error) when nothing
                # matches, which would collapse this whole expression to no
                # output at all — hence the array-wrap before indexing.
                ($stripped
                  | (try [match("\\[\\s*(-?[0-9]+\\s*(,\\s*-?[0-9]+\\s*)*)?\\]")] catch [])
                  | if length == 0 then null else (.[0].string | try fromjson catch null) end
                ) as $scavenged
                | if ($scavenged != null and ($scavenged | type) == "array"
                      and ($scavenged | all(type == "number")))
                  then {ok: true, reason: "text", numbers: $scavenged}
                  else {ok: false, reason: "unparseable", numbers: null}
                  end
              end
        end
    ' "$1"
}

# Validates a stage-2 response file into {ok, reason, text}. is_error or a
# result that is empty/all-whitespace both yield ok:false — never retried
# (stage 2 has no retry budget; the caller fails loudly either way).
validate_answer() {
    jq -c '
        if (.is_error == true) then
            {ok: false, reason: "is_error", text: null}
        else
            (.result // "") as $r
            | ($r | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $trimmed
            | if ($trimmed == "") then {ok: false, reason: "empty", text: null}
              else {ok: true, reason: "ok", text: $r}
              end
        end
    ' "$1"
}

# One --timing stderr line for one call. wall_ms/cli_duration_ms/api_ms/
# spawn_teardown_ms/cli_overhead_ms are related by:
#   spawn_teardown_ms + cli_overhead_ms + api_ms == wall_ms
# (spawn_teardown_ms = wall_ms - cli_duration_ms: process overhead outside
#  the CLI's own timer; cli_overhead_ms = cli_duration_ms - api_ms:
#  CLI-internal boot/response-handling, not further separable from the
#  CLI's own JSON.)
format_timing_line() {
    local label="$1" attempt="$2" mode="$3" wall_s="$4" resp_file="$5"
    local dur_ms api_ms cache_read cache_creation wall_ms cli_overhead_ms spawn_teardown_ms
    dur_ms="$(resp_duration_ms "$resp_file")"
    api_ms="$(resp_duration_api_ms "$resp_file")"
    cache_read="$(resp_usage_field "$resp_file" cache_read_input_tokens)"
    cache_creation="$(resp_usage_field "$resp_file" cache_creation_input_tokens)"
    wall_ms="$(awk -v s="$wall_s" 'BEGIN { printf "%d", (s * 1000) + 0.5 }')"
    cli_overhead_ms=$((dur_ms - api_ms))
    [ "$cli_overhead_ms" -lt 0 ] && cli_overhead_ms=0
    spawn_teardown_ms=$((wall_ms - dur_ms))
    [ "$spawn_teardown_ms" -lt 0 ] && spawn_teardown_ms=0
    printf '[how-do-i timing] stage=%s attempt=%s mode=%s wall_ms=%s cli_duration_ms=%s api_ms=%s cli_overhead_ms=%s spawn_teardown_ms=%s cache_read=%s cache_creation=%s\n' \
        "$label" "$attempt" "$mode" "$wall_ms" "$dur_ms" "$api_ms" "$cli_overhead_ms" "$spawn_teardown_ms" "$cache_read" "$cache_creation"
}

# Per-stage metadata object for --json's stages.{select,answer}.
stage_json() {
    local model="$1" mode="$2" attempts="$3" wall_ms="$4" resp_file="$5"
    jq -n \
        --arg model "$model" --arg mode "$mode" --argjson attempts "$attempts" --argjson wall_ms "$wall_ms" \
        --slurpfile resp "$resp_file" \
        '
        ($resp[0]) as $r
        | {
            model: $model,
            mode: $mode,
            attempts: $attempts,
            wall_ms: $wall_ms,
            cli_duration_ms: ($r.duration_ms // 0),
            api_ms: ($r.duration_api_ms // 0),
            usage: {
                input_tokens: ($r.usage.input_tokens // 0),
                output_tokens: ($r.usage.output_tokens // 0),
                cache_creation_input_tokens: ($r.usage.cache_creation_input_tokens // 0),
                cache_read_input_tokens: ($r.usage.cache_read_input_tokens // 0)
            }
          }
        '
}

# Single source of truth for the stage-1 prompt text (cold primes with the
# full index; warm assumes it's already in the resumed session). attempt
# 2+ appends a short reinforcement reminder — a genuine second attempt at
# recovery, not a byte-identical repeat.
build_stage1_prompt() {
    local question="$1" mode="$2" attempt="$3" base
    if [ "$mode" = "cold" ]; then
        base="$(printf '%s\n\nIndex:\n%s\n\nQuestion:\n%s' "$SELECT_INSTRUCTION" "$INDEX_CONTENT" "$question")"
    else
        base="$(printf 'Question:\n%s\n\nReply with a JSON array of the relevant record numbers from the index established earlier in this session, most relevant first, or [] if none are relevant. Reply with ONLY the JSON array.' "$question")"
    fi
    if [ "$attempt" -ge 2 ]; then
        printf '%s\n\nReminder: reply with ONLY a JSON array of integers (e.g. [3,7,12] or []). No prose, no explanation, no markdown code fences.\n' "$base"
    else
        printf '%s\n' "$base"
    fi
}

build_stage2_prompt() {
    local question="$1" records="$2"
    printf '%s\n\nRecords:\n%s\n\nQuestion:\n%s\n' "$ANSWER_INSTRUCTION" "$records" "$question"
}

# Times ONE `claude -p` call as a single unit (no explicit subshell around
# the timed command — verified that wrapping the timed command in `( )`
# silently breaks bash's `time` reporting; a plain simple command with
# redirects does not). Sets globals CALL_STATUS and CALL_SECONDS; writes
# stdout to $1 and stderr to "$1.stderr".
run_claude_call() {
    local out_file="$1" model="$2" prompt="$3"
    shift 3
    local time_file
    time_file="$(mktemp "$WORK/time.XXXXXX")"
    # Measured: the default harness (tool defs + default system prompt) costs
    # ~49k tokens/call; --tools "" + --exclude-dynamic-system-prompt-sections
    # cuts that to ~6k (8x). Both stages here are pure text-in/text-out, so
    # neither needs tools. MAX_THINKING_TOKENS=0 is exported at top of file.
    # HOWDOI_CLAUDE_BIN may be multi-word (e.g. "orwrap claude" for an
    # OpenRouter gateway), so split it into words before exec.
    local claude_cmd
    read -r -a claude_cmd <<<"$CLAUDE_BIN"
    { time "${claude_cmd[@]}" -p --output-format json --model "$model" --tools "" --exclude-dynamic-system-prompt-sections "$@" <<<"$prompt" >"$out_file" 2>"$out_file.stderr"; } 2>"$time_file"
    CALL_STATUS=$?
    CALL_SECONDS="$(cat "$time_file" 2>/dev/null || true)"
    [ -n "$CALL_SECONDS" ] || CALL_SECONDS="0.000"
    rm -f "$time_file"
}

# --- tier 1: --help works even without jq ---
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 \
    || die "jq not found. Install jq (https://jqlang.org) — how-do-i.sh requires it to parse Claude CLI JSON output."

# --- tier 2: internal test-support seams (see header comment) ---
case "${1:-}" in
    --internal-parse-selection)
        shift
        [ "$#" -eq 1 ] || { echo "how-do-i: --internal-parse-selection needs exactly 1 arg: <response-json-file|->" >&2; exit 2; }
        f="$1"; [ "$f" = "-" ] && f=/dev/stdin
        [ "$f" = "/dev/stdin" ] || [ -f "$f" ] || { echo "how-do-i: file not found: $f" >&2; exit 2; }
        sel="$(parse_selection "$f")"
        ok="$(printf '%s' "$sel" | jq -r '.ok')"
        if [ "$ok" = "true" ]; then
            nums="$(printf '%s' "$sel" | jq -r '.numbers | map(tostring) | join(" ")')"
            echo "OK $nums"
            exit 0
        fi
        reason="$(printf '%s' "$sel" | jq -r '.reason')"
        echo "FAIL $reason"
        exit 1
        ;;
    --internal-validate-answer)
        shift
        [ "$#" -eq 1 ] || { echo "how-do-i: --internal-validate-answer needs exactly 1 arg: <response-json-file|->" >&2; exit 2; }
        f="$1"; [ "$f" = "-" ] && f=/dev/stdin
        [ "$f" = "/dev/stdin" ] || [ -f "$f" ] || { echo "how-do-i: file not found: $f" >&2; exit 2; }
        val="$(validate_answer "$f")"
        ok="$(printf '%s' "$val" | jq -r '.ok')"
        if [ "$ok" = "true" ]; then
            text="$(printf '%s' "$val" | jq -r '.text')"
            printf 'OK %s\n' "$text"
            exit 0
        fi
        reason="$(printf '%s' "$val" | jq -r '.reason')"
        echo "FAIL $reason"
        exit 1
        ;;
    --internal-format-timing)
        shift
        [ "$#" -eq 5 ] || { echo "how-do-i: --internal-format-timing needs exactly 5 args: <label> <attempt> <mode> <wall_seconds> <response-json-file>" >&2; exit 2; }
        format_timing_line "$1" "$2" "$3" "$4" "$5"
        exit 0
        ;;
esac

# --- main flag parsing ---
QUESTION_TEXT=""
QUESTION_FILE=""
INDEX_DIR="${HOWDOI_INDEX_DIR:-$(procedures_state_dir)/how-do-i-index}"
REBUILD=false
SELECT_MODEL="haiku"
ANSWER_MODEL="sonnet"
EXPAND_LINKS=false
JSON_OUT=false
DRY_RUN=false
TIMING=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --question)      QUESTION_TEXT="${2:-}"; shift 2 ;;
        --question-file) QUESTION_FILE="${2:-}"; shift 2 ;;
        --index-dir)     INDEX_DIR="${2:-}"; shift 2 ;;
        --rebuild)       REBUILD=true; shift ;;
        --select-model)  SELECT_MODEL="${2:-}"; shift 2 ;;
        --answer-model)  ANSWER_MODEL="${2:-}"; shift 2 ;;
        --expand-links)  EXPAND_LINKS=true; shift ;;
        --json)          JSON_OUT=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --timing)        TIMING=true; shift ;;
        --help|-h)       usage; exit 0 ;;
        *) echo "how-do-i: unknown flag: $1 (see --help)" >&2; exit 2 ;;
    esac
done

if [ -n "$QUESTION_TEXT" ] && [ -n "$QUESTION_FILE" ]; then
    echo "how-do-i: --question and --question-file are mutually exclusive" >&2
    exit 2
fi
if [ -z "$QUESTION_TEXT" ] && [ -z "$QUESTION_FILE" ]; then
    echo "how-do-i: --question or --question-file is required (see --help)" >&2
    exit 2
fi
if $REBUILD && $DRY_RUN; then
    echo "how-do-i: --rebuild and --dry-run are incompatible (--dry-run reads an existing index only, it never builds one)" >&2
    exit 2
fi

if [ -n "$QUESTION_FILE" ]; then
    [ -f "$QUESTION_FILE" ] || die "question file not found: $QUESTION_FILE"
    QUESTION="$(cat "$QUESTION_FILE")"
else
    QUESTION="$QUESTION_TEXT"
fi
[ -n "$(printf '%s' "$QUESTION" | tr -d '[:space:]')" ] || die "question text is empty"

export MAX_THINKING_TOKENS=0

INDEX_TXT="$INDEX_DIR/index.txt"
MAP_TSV="$INDEX_DIR/map.tsv"
SESSION_ID_FILE="$INDEX_DIR/session.id"
SESSION_FP_FILE="$INDEX_DIR/session.fingerprint"
ROOTS_STAMP_FILE="$INDEX_DIR/roots.stamp"
CURRENT_ROOTS="$(_stores_resolve_roots_spec)"

if $DRY_RUN; then
    [ -f "$INDEX_TXT" ] || die "--dry-run needs an existing index at $INDEX_TXT (run without --dry-run first to build one, or point --index-dir at an existing index)"
else
    # Cache invalidation: --rebuild, a missing index/map/stamp, a
    # roots.stamp recording a DIFFERENT root set than CURRENT_ROOTS, or any
    # *.md under the current roots newer than index.txt all force a
    # rebuild. Before this, the gate below only checked file existence, so
    # an index built before CODEX_STORE_ROOTS was set (or before it
    # changed) never invalidated on its own — a split-store cutover kept
    # answering from a stale single-root index indefinitely, even after the
    # env var was set and the cache had already been rebuilt at least once.
    NEED_BUILD=false
    if $REBUILD || [ ! -f "$INDEX_TXT" ] || [ ! -f "$MAP_TSV" ] || [ ! -f "$ROOTS_STAMP_FILE" ]; then
        NEED_BUILD=true
    elif [ "$(sed -n '1p' "$ROOTS_STAMP_FILE" 2>/dev/null || true)" != "$CURRENT_ROOTS" ]; then
        NEED_BUILD=true
    else
        # Cheap staleness probe: lib/stores.sh (sourced above) is the single
        # source of truth for root-string -> path-array splitting (also used
        # by build-record-index.sh and lint-frontmatter.sh) — reusing it here
        # rather than re-parsing CURRENT_ROOTS inline is what keeps this
        # probe's path list from ever diverging from what a rebuild itself
        # scans.
        _stores_split_roots "$CURRENT_ROOTS"
        EXISTING_ROOTS=()
        for _root in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
            [ -d "$_root" ] && EXISTING_ROOTS+=("$_root")
        done
        unset _root
        if [ "${#EXISTING_ROOTS[@]}" -gt 0 ] && \
           [ -n "$(find "${EXISTING_ROOTS[@]}" -name '*.md' -newer "$INDEX_TXT" -print -quit 2>/dev/null)" ]; then
            NEED_BUILD=true
        fi
    fi

    if $NEED_BUILD; then
        BUILD_SCRIPT="$SCRIPT_DIR/build-record-index.sh"
        [ -f "$BUILD_SCRIPT" ] || die "build-record-index.sh not found at $BUILD_SCRIPT (expected sibling script)"
        mkdir -p "$INDEX_DIR"
        bash "$BUILD_SCRIPT" --out "$INDEX_DIR"
        build_status=$?
        [ "$build_status" -eq 0 ] || die "build-record-index.sh failed (exit $build_status)"
        [ -f "$INDEX_TXT" ] || die "build-record-index.sh did not produce $INDEX_TXT"
        [ -f "$MAP_TSV" ] || die "build-record-index.sh did not produce $MAP_TSV"
        # Atomic: write-then-rename so a crash mid-write never leaves a
        # roots.stamp that is half-written or stale-but-present (which would
        # wrongly read as "matches CURRENT_ROOTS" on the next run).
        ROOTS_STAMP_TMP="$ROOTS_STAMP_FILE.tmp.$$"
        printf '%s\n%s\n' "$CURRENT_ROOTS" "$(date +%s 2>/dev/null || echo 0)" > "$ROOTS_STAMP_TMP"
        mv "$ROOTS_STAMP_TMP" "$ROOTS_STAMP_FILE"
    fi
fi

INDEX_CONTENT="$(cat "$INDEX_TXT")"
CURRENT_FP="$(compute_fingerprint "$INDEX_TXT")"

WARM=false
RESUME_SID=""
if [ -f "$SESSION_ID_FILE" ] && [ -f "$SESSION_FP_FILE" ]; then
    STORED_FP="$(cat "$SESSION_FP_FILE" 2>/dev/null || true)"
    STORED_SID="$(cat "$SESSION_ID_FILE" 2>/dev/null || true)"
    if [ -n "$STORED_FP" ] && [ "$STORED_FP" = "$CURRENT_FP" ] && [ -n "$STORED_SID" ]; then
        WARM=true
        RESUME_SID="$STORED_SID"
    fi
fi
MODE_LABEL="cold"; $WARM && MODE_LABEL="warm"

if $DRY_RUN; then
    if $JSON_OUT; then
        jq -n \
            --argjson dry_run true \
            --arg mode "$MODE_LABEL" \
            --arg select_model "$SELECT_MODEL" \
            --arg answer_model "$ANSWER_MODEL" \
            --arg stage1_prompt "$(build_stage1_prompt "$QUESTION" "$MODE_LABEL" 1)" \
            --arg stage2_prompt_template "$(build_stage2_prompt "$QUESTION" "<compiled records go here — depend on stage 1 live selection, not available in --dry-run>")" \
            '{dry_run: $dry_run, mode: $mode, select_model: $select_model, answer_model: $answer_model, stage1_prompt: $stage1_prompt, stage2_prompt_template: $stage2_prompt_template}'
    else
        echo "=== how-do-i --dry-run ==="
        echo "index-dir: $INDEX_DIR"
        echo "mode: $MODE_LABEL"
        echo "select-model: $SELECT_MODEL"
        echo "answer-model: $ANSWER_MODEL"
        echo
        echo "--- STAGE 1 PROMPT (select, model=$SELECT_MODEL, mode=$MODE_LABEL) ---"
        build_stage1_prompt "$QUESTION" "$MODE_LABEL" 1
        echo
        echo "--- STAGE 2 PROMPT TEMPLATE (answer, model=$ANSWER_MODEL) ---"
        echo "(actual compiled records depend on stage 1 live selection; not available in --dry-run)"
        build_stage2_prompt "$QUESTION" "<compiled records go here>"
        echo
        echo "No model calls were made (--dry-run)."
    fi
    exit 0
fi

CLAUDE_BIN="${HOWDOI_CLAUDE_BIN:-claude}"
# Multi-word values ("orwrap claude") resolve on their first word.
read -r -a _claudewords <<<"$CLAUDE_BIN"
command -v "${_claudewords[0]}" >/dev/null 2>&1 \
    || die "'$CLAUDE_BIN' CLI not found. Install Claude Code, or set HOWDOI_CLAUDE_BIN to override (tests use this to inject a stub)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/how-do-i.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- stage 1: select, up to 2 attempts. Only an "unparseable" reply (not
#     is_error, not a CLI-process failure) consumes the retry budget — see
#     parse_selection's header comment. ---
ATTEMPT=1
MAX_ATTEMPTS=2
SEL_OK=false
NUMBERS=()
LAST_RESP_FILE=""
STAGE1_ATTEMPTS_MADE=0
USE_SCHEMA=true
ORWRAP_TRIED=false
RETRY_SAME_ATTEMPT=false

while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ] && [ "$SEL_OK" = false ]; do
    resp_file="$WORK/stage1-attempt${ATTEMPT}.json"
    prompt="$(build_stage1_prompt "$QUESTION" "$MODE_LABEL" "$ATTEMPT")"

    extra_args=()
    # Gateways behind ANTHROPIC_BASE_URL (e.g. OpenRouter) may silently drop
    # --json-schema: measured structured_output=null, result="null". After the
    # first such reply, retry under the plain text contract instead.
    $USE_SCHEMA && extra_args+=(--json-schema "$STAGE1_SCHEMA")
    $WARM && extra_args+=(--resume "$RESUME_SID")

    run_claude_call "$resp_file" "$SELECT_MODEL" "$prompt" "${extra_args[@]}"
    # A stored session can become unresumable (CLI/model/auth drift since it
    # was primed). That must not brick the tool: drop the poisoned cache and
    # re-prime cold ONCE. Measured live: resume of a stale session exits 1
    # with "unrecognized_model".
    RETRY_SAME_ATTEMPT=false
    if [ "$CALL_STATUS" -ne 0 ] && $WARM; then
        echo "how-do-i: warm session unresumable — clearing stale cache and re-priming cold" >&2
        rm -f "$INDEX_DIR/session.id" "$INDEX_DIR/session.fingerprint"
        WARM=false
        MODE_LABEL="cold"
        RESUME_SID=""
        ATTEMPT=$((ATTEMPT - 1))   # retry this attempt number, now cold
        RETRY_SAME_ATTEMPT=true
    fi
    # PLUGIN ADAPTATION: no upstream counterpart. orchard-codex's how-do-i.sh
    # always reaches the first-party Anthropic API, so it needs no gateway
    # fallback. The installed plugin can run on a box whose Claude Code is
    # routed through a third-party gateway by a wrapper (orwrap) that injects
    # its config via --settings — visible only to the CHILD process, so this
    # script cannot sniff for it and must fall back on observed behavior.
    # Gateway fallback: when a RAW `claude` child dies with an auth-shaped
    # failure (gateway env lives in settings.json, which only the child sees,
    # so env-sniffing cannot predict it) and the orwrap wrapper exists, retry
    # the whole attempt through the wrapper. Measured live both ways.
    if [ "$CALL_STATUS" -ne 0 ] && ! $ORWRAP_TRIED \
       && [ "${_claudewords[0]}" = "claude" ] \
       && command -v orwrap >/dev/null 2>&1; then
        echo "how-do-i: raw claude spawn failed — retrying via orwrap wrapper" >&2
        # run_claude_call re-splits $CLAUDE_BIN, so the wrapper must land THERE:
        # reassigning _claudewords alone silently re-ran raw claude.
        CLAUDE_BIN="orwrap claude"
        read -r -a _claudewords <<<"$CLAUDE_BIN"
        ORWRAP_TRIED=true
        rm -f "$INDEX_DIR/session.id" "$INDEX_DIR/session.fingerprint"
        WARM=false; MODE_LABEL="cold"; RESUME_SID=""
        ATTEMPT=$((ATTEMPT - 1))
        RETRY_SAME_ATTEMPT=true
    fi
    LAST_RESP_FILE="$resp_file"
    STAGE1_ATTEMPTS_MADE="$ATTEMPT"
    STAGE1_WALL_S="$CALL_SECONDS"

    if $TIMING; then
        format_timing_line "select" "$ATTEMPT" "$MODE_LABEL" "$CALL_SECONDS" "$resp_file" >&2
    fi

    if [ "$CALL_STATUS" -ne 0 ]; then
        if $RETRY_SAME_ATTEMPT; then
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi
        err_detail="$(cat "${resp_file}.stderr" 2>/dev/null | head -c 300)"
        die "stage 1 (select) CLI invocation failed (exit $CALL_STATUS): ${err_detail:-no stderr captured}"
    fi

    sel="$(parse_selection "$resp_file")"
    ok="$(printf '%s' "$sel" | jq -r '.ok')"

    if [ "$ok" = "true" ]; then
        SEL_OK=true
        while IFS= read -r n; do
            [ -n "$n" ] && NUMBERS+=("$n")
        done < <(printf '%s' "$sel" | jq -r '.numbers[]')
        break
    fi

    reason="$(printf '%s' "$sel" | jq -r '.reason')"
    if [ "$reason" = "is_error" ]; then
        err_detail="$(jq -r '.result // "no error detail available"' "$resp_file" 2>/dev/null)"
        die "stage 1 (select) failed: $err_detail"
    fi

    # unparseable / structured_output-shape: retry once. If the reply carried
    # no structured_output at all, the endpoint ignored --json-schema — drop
    # it for the retry so the text contract (fence-tolerant parse) applies.
    if [ "$(jq -r 'has("structured_output") and (.structured_output != null)' "$resp_file" 2>/dev/null)" != "true" ] && $USE_SCHEMA; then
        USE_SCHEMA=false
        echo "how-do-i: structured output not honored by this endpoint — retrying with plain-text contract" >&2
    fi
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$SEL_OK" != true ]; then
    last_text="$(resp_result_text "$LAST_RESP_FILE" | head -c 300)"
    die "stage 1 (select) did not return a parseable JSON array of numbers after $STAGE1_ATTEMPTS_MADE attempt(s). Last reply (truncated): $last_text"
fi

# Persist the session id/fingerprint after ANY successful stage-1 call (cold
# or warm) — never after a failed one, so a failed prime/resume can't poison
# the cache. Re-persisting on a warm success is a safety net in case a future
# CLI ever rotates session_id across --resume calls; today it is observed to
# echo the same id back, so this is normally a same-value rewrite.
new_sid="$(resp_session_id "$LAST_RESP_FILE")"
if [ -n "$new_sid" ]; then
    printf '%s' "$new_sid" > "$SESSION_ID_FILE"
    printf '%s' "$CURRENT_FP" > "$SESSION_FP_FILE"
fi

STAGE1_WALL_MS="$(awk -v s="$STAGE1_WALL_S" 'BEGIN { printf "%d", (s * 1000) + 0.5 }')"
STAGE1_JSON="$(stage_json "$SELECT_MODEL" "$MODE_LABEL" "$STAGE1_ATTEMPTS_MADE" "$STAGE1_WALL_MS" "$LAST_RESP_FILE")"

RESOLVED_IDS=()
if [ "${#NUMBERS[@]}" -gt 0 ]; then
    for n in "${NUMBERS[@]}"; do
        id="$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' "$MAP_TSV")"
        [ -n "$id" ] && RESOLVED_IDS+=("$id")
    done
fi

# An empty selection is stage 1 ANSWERING "nothing here is relevant", not
# failing. compile-records.sh rightly rejects an empty --nums (it has no
# records to compile), so the short-circuit belongs here in the caller:
# hand it nothing and the whole pipeline used to exit 1 on a correct result.
if [ "${#NUMBERS[@]}" -eq 0 ]; then
    NOT_FOUND_TEXT="NOT FOUND: no record in the index is relevant to this question.

Nothing was compiled and no answer stage was run. Proceed without a codex
record, or re-run with --rebuild if you expect the index to cover this (a
stale or partially-built index selects nothing for questions it should match)."
    if $JSON_OUT; then
        jq -n \
            --arg answer "$NOT_FOUND_TEXT" \
            --argjson stage1 "$STAGE1_JSON" \
            '{answer: $answer, not_found: true, selected_numbers: [], resolved_ids: [], stages: {select: $stage1, answer: null}}'
    else
        printf '%s\n' "$NOT_FOUND_TEXT"
    fi
    exit 0
fi

NUMS_CSV="$(IFS=,; echo "${NUMBERS[*]}")"

COMPILE_SCRIPT="$SCRIPT_DIR/compile-records.sh"
[ -f "$COMPILE_SCRIPT" ] || die "compile-records.sh not found at $COMPILE_SCRIPT (expected sibling script)"

compile_args=(--map "$MAP_TSV" --nums "$NUMS_CSV")
$EXPAND_LINKS && compile_args+=(--expand-links)

COMPILE_OUT_FILE="$WORK/compiled.txt"
COMPILE_ERR_FILE="$WORK/compiled.err"
bash "$COMPILE_SCRIPT" "${compile_args[@]}" >"$COMPILE_OUT_FILE" 2>"$COMPILE_ERR_FILE"
compile_status=$?
[ "$compile_status" -eq 0 ] || die "compile-records.sh failed (exit $compile_status): $(cat "$COMPILE_ERR_FILE" 2>/dev/null | head -c 500)"

COMPILED_RECORDS="$(cat "$COMPILE_OUT_FILE")"

# --- stage 2: answer, single attempt, no retry (see header comment) ---
STAGE2_RESP="$WORK/stage2.json"
STAGE2_PROMPT="$(build_stage2_prompt "$QUESTION" "$COMPILED_RECORDS")"
run_claude_call "$STAGE2_RESP" "$ANSWER_MODEL" "$STAGE2_PROMPT"
STAGE2_WALL_S="$CALL_SECONDS"

if $TIMING; then
    format_timing_line "answer" 1 "n/a" "$STAGE2_WALL_S" "$STAGE2_RESP" >&2
fi

if [ "$CALL_STATUS" -ne 0 ]; then
    err_detail="$(cat "${STAGE2_RESP}.stderr" 2>/dev/null | head -c 300)"
    die "stage 2 (answer) CLI invocation failed (exit $CALL_STATUS): ${err_detail:-no stderr captured}"
fi

val="$(validate_answer "$STAGE2_RESP")"
vok="$(printf '%s' "$val" | jq -r '.ok')"
if [ "$vok" != "true" ]; then
    vreason="$(printf '%s' "$val" | jq -r '.reason')"
    if [ "$vreason" = "is_error" ]; then
        err_detail="$(jq -r '.result // "no error detail available"' "$STAGE2_RESP" 2>/dev/null)"
        die "stage 2 (answer) failed: $err_detail"
    fi
    die "stage 2 (answer) returned empty output"
fi
ANSWER_TEXT="$(printf '%s' "$val" | jq -r '.text')"

STAGE2_WALL_MS="$(awk -v s="$STAGE2_WALL_S" 'BEGIN { printf "%d", (s * 1000) + 0.5 }')"
STAGE2_JSON="$(stage_json "$ANSWER_MODEL" "n/a" 1 "$STAGE2_WALL_MS" "$STAGE2_RESP")"

if $JSON_OUT; then
    numbers_json="[]"
    [ "${#NUMBERS[@]}" -gt 0 ] && numbers_json="$(printf '%s\n' "${NUMBERS[@]}" | jq -R 'tonumber' | jq -cs '.')"
    resolved_ids_json="[]"
    [ "${#RESOLVED_IDS[@]}" -gt 0 ] && resolved_ids_json="$(printf '%s\n' "${RESOLVED_IDS[@]}" | jq -R '.' | jq -cs '.')"

    jq -n \
        --arg answer "$ANSWER_TEXT" \
        --argjson selected_numbers "$numbers_json" \
        --argjson resolved_ids "$resolved_ids_json" \
        --argjson stage1 "$STAGE1_JSON" \
        --argjson stage2 "$STAGE2_JSON" \
        '{answer: $answer, selected_numbers: $selected_numbers, resolved_ids: $resolved_ids, stages: {select: $stage1, answer: $stage2}}'
else
    printf '%s\n' "$ANSWER_TEXT"
fi
