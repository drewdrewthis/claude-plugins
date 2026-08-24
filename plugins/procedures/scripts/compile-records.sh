#!/usr/bin/env bash
# compile-records.sh — Stage 2 of the two-stage retrieval pipeline: expands a
# stage-1 selection (record numbers, or ids as a fallback) into the full text
# of those records, ready to hand to a stronger model. Pure and deterministic
# — no model calls, no corpus scanning; it only reads exactly the map.tsv
# row(s) and record file(s) the selection and (optionally) their links name.
#
# INPUT CONTRACT — map.tsv, produced by build-record-index.sh (treated here
# as a fixed, external contract):
#   one line per record, tab-separated:  N<TAB>id<TAB>path
#   N is a 1-based integer; path is absolute.
#
# USAGE
#   compile-records.sh --map PATH \
#       [--nums "1,5,9" | --nums-file PATH | --ids "a,b"] \
#       [--expand-links] [--link-depth N] [--max-bytes N] [--strict]
#
# SELECTION (choose exactly one source)
#   --nums LIST        comma and/or whitespace separated integers. Also
#                       tolerates the raw shape a model actually emits: a
#                       bare JSON array (`[394, 314]`) or a ```-fenced one
#                       (```json[394, 314]```). Markdown fences, a "json"
#                       language tag, and []{}, punctuation are stripped
#                       before parsing; a token that still isn't a plain
#                       integer after that is parser noise and is dropped
#                       silently — only a well-formed number absent from
#                       map.tsv is "unresolvable" (see LOUD FAILURE below).
#                       Duplicates are ignored, first-seen order preserved.
#   --nums-file PATH    same content/parsing as --nums, read from a file.
#   --ids LIST          same list syntax, of id strings (map.tsv column 2)
#                       instead of numbers — fallback path for a caller that
#                       selected by id. Every non-empty token is kept (no
#                       integer filter).
#
# LINK EXPANSION (--expand-links)
#   After emitting a selected record, also emit the records referenced by
#   its frontmatter `links:` value, resolved against map.tsv's id column. A
#   link target absent from map.tsv is reported, never fatal.
#   --link-depth N      hop bound from each directly-selected record
#                       (default 1; 0 disables expansion outright). A global
#                       visited set makes this cycle-safe regardless of the
#                       bound: an id is never recursed into, or emitted,
#                       twice, however the corpus's links loop back.
#
# OUTPUT (stdout) — nothing else; every diagnostic goes to stderr:
#   For each emitted record, in selection order (a record's link-expansions
#   immediately after it), blank line between records:
#     ===== RECORD <N> <id> (<path>) =====
#     <full file contents>
#
# BUDGET (--max-bytes N)
#   Caps total stdout bytes. Directly-selected records are accepted before
#   link-expanded ones when the budget is tight — greedy, priority-ordered,
#   so a direct record later in the list can still bump an earlier expansion
#   record out. Whatever is accepted is still emitted in normal selection
#   order. Anything that would push the total over N is dropped and named
#   explicitly on stderr — never silently truncated. (The per-record size
#   used for this accounting is header+content bytes only, not the 1-2 byte
#   blank-line separator between records — negligible against real record
#   sizes, and keeps the budget check independent of a record's position.)
#
# LOUD FAILURE (stderr only)
#   - a requested number/id absent from map.tsv: reported unresolvable with
#     the offending value (the primary hallucination detector for this
#     pipeline — a model selecting by id has fabricated ids before).
#   - a links: target id absent from map.tsv: reported, never fatal.
#   - a map.tsv path that doesn't exist or isn't readable: reported, that
#     record is skipped (not counted as emitted), never fatal on its own.
#   - one final summary line: requested/emitted/link-expanded/unresolvable
#     counts and total bytes.
#
# EXIT CODES
#   0  ran; any per-record problems were reported but didn't leave the
#      compile empty (see stderr).
#   1  --map or --nums-file was missing/unreadable; the selection parsed to
#      zero usable numbers/ids; zero records ended up emitted for any
#      reason (an empty compile that looks complete is worse than a loud
#      failure — this holds with or without --strict); or --strict was
#      given and at least one requested number/id was unresolvable.
#   2  usage error: unknown/missing flag, more than one selection source, or
#      a non-integer --link-depth/--max-bytes.
#
# Pure bash + awk; no network, no model calls. Sources scripts/lib/
# frontmatter.sh's frontmatter_block()/fm_value() (the same SSOT readers
# lint-frontmatter.sh uses) and reuses the link-token shape + stripq()
# quote-stripper shape proven against the old awk scanner (kept in-line:
# AWK_STRIPQ_FN below — awk has no cross-file import, so it is kept in this
# ONE place rather than as drifting per-snippet copies).

set -uo pipefail

prog="compile-records"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/frontmatter.sh
source "$SCRIPT_DIR/lib/frontmatter.sh"

die() { printf '%s: %s\n' "$prog" "$1" >&2; exit 1; }
usage_err() { printf '%s: %s (see --help)\n' "$prog" "$1" >&2; exit 2; }

usage() {
    cat <<'EOF'
Usage: compile-records.sh --map PATH [selection] [options]

Stage 2 of the two-stage retrieval pipeline: expands a stage-1 selection
(record numbers, or ids as a fallback) into the full text of those records.
No model calls, no scanning — a pure, deterministic expansion of map.tsv.

Required:
  --map PATH             map.tsv from build-record-index.sh:
                          N<TAB>id<TAB>path per line.

Selection (choose exactly one):
  --nums LIST             comma/whitespace separated integers. Also accepts
                          a bare or ```-fenced JSON array (the shape a model
                          actually emits) — fences, a "json" tag, and
                          []{}, are stripped before parsing.
  --nums-file PATH        same parsing as --nums, read from a file.
  --ids LIST              same list syntax, of id strings instead of numbers.

Options:
  --expand-links          also emit records linked from each selected record.
  --link-depth N          hop bound for expansion (default 1; 0 = disabled).
  --max-bytes N           cap total stdout bytes; direct records are kept
                          over link-expanded ones when tight; drops are
                          named on stderr, never silent.
  --strict                exit non-zero if any requested number/id was
                          unresolvable.
  --help, -h              show this help and exit 0.

Output (stdout): one block per emitted record, in selection order (a
record's link-expansions immediately after it), blank line between records:
  ===== RECORD <N> <id> (<path>) =====
  <full file contents>
Nothing else on stdout — every diagnostic goes to stderr, including a final
one-line summary (requested/emitted/link-expanded/unresolvable counts, bytes).

Exit codes: 0 ran (see stderr for any per-record problems); 1 --map/
--nums-file was bad, the selection parsed to zero numbers/ids, zero records
ended up emitted, or --strict hit an unresolvable request; 2 usage error.
EOF
}

# Strips one matching pair of outer quotes from an already-trimmed token
# (the same shape the retired awk scanner used). Kept in this ONE variable
# so every awk snippet below shares one definition instead of drifting
# copies.
AWK_STRIPQ_FN="$(cat <<'AWKEOF'
function stripq(v,   n) {
    n = length(v)
    if (n < 2) return v
    if (substr(v, 1, 1) == "\"" && substr(v, n, 1) == "\"") return substr(v, 2, n - 2)
    if (substr(v, 1, 1) == "'"  && substr(v, n, 1) == "'")  return substr(v, 2, n - 2)
    return v
}
AWKEOF
)"

# tokenize_list <raw> <mode>: normalizes a raw --nums/--nums-file/--ids
# value into deduped, first-seen-order tokens (one per line on stdout).
# Strips backtick fences and []{}, punctuation, then splits on whitespace —
# handles a plain list, a bare JSON array, and a fenced JSON array
# uniformly. mode=nums additionally keeps only integer-looking tokens (which
# also drops a bare "json" language tag); mode=ids keeps every non-empty
# token.
tokenize_list() {
    local raw="$1" mode="$2"
    printf '%s\n' "$raw" | awk -v mode="$mode" "$AWK_STRIPQ_FN"'
        {
            line = $0
            gsub(/`/, " ", line)
            gsub(/[{}\[\],]/, " ", line)
            n = split(line, toks, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (t == "") continue
                t = stripq(t)
                if (t == "") continue
                if (mode == "nums") {
                    if (t !~ /^[0-9]+$/) continue
                } else if (tolower(t) == "json") {
                    continue
                }
                if (!(t in seen)) { seen[t] = 1; print t }
            }
        }
    '
}

# extract_link_ids <links_raw>: prints every candidate link-target id token
# from a frontmatter links: value's raw RHS (fm_value's output), one per
# line. Category-label tokens ("procedures:", "decisions:", ...) carry a
# trailing colon and are dropped; ids never do (the qlinks heuristic this
# script's brief specifies).
extract_link_ids() {
    local raw="$1"
    printf '%s\n' "$raw" | awk "$AWK_STRIPQ_FN"'
        {
            line = $0
            gsub(/[{}\[\],]/, " ", line)
            n = split(line, toks, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (t == "") continue
                if (t ~ /:$/) continue
                t = stripq(t)
                if (t != "") print t
            }
        }
    '
}

# --- early --help dispatch, before flag validation (same precedent as
#     bench-index-selection.sh) ---
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
esac

# --- flag parsing ---
MAP_FILE=""
NUMS_RAW=""
NUMS_FILE=""
IDS_RAW=""
SAW_NUMS=0
SAW_NUMS_FILE=0
SAW_IDS=0
SEL_FLAGS=0
EXPAND_LINKS=0
LINK_DEPTH=1
MAX_BYTES=""
STRICT=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --map)          MAP_FILE="${2:-}"; shift 2 ;;
        --nums)         NUMS_RAW="${2:-}"; SAW_NUMS=1; SEL_FLAGS=$((SEL_FLAGS + 1)); shift 2 ;;
        --nums-file)    NUMS_FILE="${2:-}"; SAW_NUMS_FILE=1; SEL_FLAGS=$((SEL_FLAGS + 1)); shift 2 ;;
        --ids)          IDS_RAW="${2:-}"; SAW_IDS=1; SEL_FLAGS=$((SEL_FLAGS + 1)); shift 2 ;;
        --expand-links) EXPAND_LINKS=1; shift ;;
        --link-depth)   LINK_DEPTH="${2:-}"; shift 2 ;;
        --max-bytes)    MAX_BYTES="${2:-}"; shift 2 ;;
        --strict)       STRICT=1; shift ;;
        --help|-h)      usage; exit 0 ;;
        *) usage_err "unknown flag: $1" ;;
    esac
done

[ -n "$MAP_FILE" ] || usage_err "--map is required"
[ "$SEL_FLAGS" -le 1 ] || usage_err "choose exactly one of --nums / --nums-file / --ids"

# Validated with [ -ge ]/[ -lt ]/case-glob below, never bash arithmetic
# ($(( ))) directly on the raw flag string — test's numeric comparison
# parses a leading-zero string like "008" as decimal 8, but $(( )) rejects
# it as invalid octal. Keep it this way; don't "simplify" to (( )).
case "$LINK_DEPTH" in
    ''|*[!0-9]*) usage_err "--link-depth needs a non-negative integer, got '$LINK_DEPTH'" ;;
esac
if [ -n "$MAX_BYTES" ]; then
    case "$MAX_BYTES" in
        ''|*[!0-9]*) usage_err "--max-bytes needs a non-negative integer, got '$MAX_BYTES'" ;;
    esac
fi

[ -f "$MAP_FILE" ] && [ -r "$MAP_FILE" ] || die "map file not found or unreadable: $MAP_FILE"

# --- resolve the selection source into SEL_MODE + deduped SEL_LIST ---
SEL_MODE="nums"
TOKENS=""
if [ "$SAW_NUMS" -eq 1 ]; then
    SEL_MODE="nums"
    TOKENS="$(tokenize_list "$NUMS_RAW" nums)"
elif [ "$SAW_NUMS_FILE" -eq 1 ]; then
    [ -f "$NUMS_FILE" ] && [ -r "$NUMS_FILE" ] || die "--nums-file not found or unreadable: $NUMS_FILE"
    SEL_MODE="nums"
    TOKENS="$(tokenize_list "$(cat "$NUMS_FILE")" nums)"
elif [ "$SAW_IDS" -eq 1 ]; then
    SEL_MODE="ids"
    TOKENS="$(tokenize_list "$IDS_RAW" ids)"
fi

[ -n "$TOKENS" ] || die "empty selection: no valid numbers/ids parsed (need one of --nums/--nums-file/--ids)"

SEL_LIST=()
while IFS= read -r line; do
    [ -n "$line" ] && SEL_LIST+=("$line")
done <<< "$TOKENS"

# --- load map.tsv: N<->id<->path, both directions, O(1) lookup ---
declare -A ID_BY_NUM=()
declare -A PATH_BY_NUM=()
declare -A NUM_BY_ID=()
declare -A PATH_BY_ID=()

while IFS=$'\t' read -r m_n m_id m_path || [ -n "$m_n" ]; do
    [ -n "$m_n" ] || continue
    ID_BY_NUM["$m_n"]="$m_id"
    PATH_BY_NUM["$m_n"]="$m_path"
    NUM_BY_ID["$m_id"]="$m_n"
    PATH_BY_ID["$m_id"]="$m_path"
done < "$MAP_FILE"

# --- resolve selection + link expansion into an ordered, cycle-safe queue ---
declare -A VISITED=()
declare -A IS_EXPANSION=()
OUTPUT_QUEUE=()
UNRESOLVED_REQUESTED=()

expand_links_from() {
    local from_id="$1" depth="$2" maxdepth="$3"
    local from_path="${PATH_BY_ID[$from_id]:-}"
    [ -n "$from_path" ] || return 0
    [ -f "$from_path" ] && [ -r "$from_path" ] || return 0

    local block links_val cand
    block="$(frontmatter_block "$from_path")"
    links_val="$(fm_value "$block" links)"
    [ -n "$links_val" ] || return 0

    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        # cycle safety: never recurse into, or re-emit, an already-visited id
        [ -n "${VISITED[$cand]+x}" ] && continue

        local target_path="${PATH_BY_ID[$cand]:-}"
        if [ -z "$target_path" ]; then
            printf '%s: unresolvable link target: %s (linked from %s)\n' "$prog" "$cand" "$from_id" >&2
            continue
        fi

        VISITED["$cand"]=1
        IS_EXPANSION["$cand"]=1
        OUTPUT_QUEUE+=("$cand")
        if [ "$depth" -lt "$maxdepth" ]; then
            expand_links_from "$cand" "$((depth + 1))" "$maxdepth"
        fi
    done < <(extract_link_ids "$links_val")
}

for tok in "${SEL_LIST[@]}"; do
    if [ "$SEL_MODE" = "nums" ]; then
        rid="${ID_BY_NUM[$tok]:-}"
    else
        if [ -n "${PATH_BY_ID[$tok]+x}" ]; then rid="$tok"; else rid=""; fi
    fi

    if [ -z "$rid" ]; then
        UNRESOLVED_REQUESTED+=("$tok")
        printf '%s: unresolvable %s: %s\n' "$prog" "$SEL_MODE" "$tok" >&2
        continue
    fi

    # already queued: a duplicate request, or beaten here by an earlier
    # record's link-expansion. Either way it's already in the queue once.
    [ -n "${VISITED[$rid]+x}" ] && continue

    VISITED["$rid"]=1
    OUTPUT_QUEUE+=("$rid")

    if [ "$EXPAND_LINKS" -eq 1 ] && [ "$LINK_DEPTH" -ge 1 ]; then
        expand_links_from "$rid" 1 "$LINK_DEPTH"
    fi
done

REQUESTED_COUNT="${#SEL_LIST[@]}"
UNRESOLVED_COUNT="${#UNRESOLVED_REQUESTED[@]}"

# --- materialize each queued record's exact output block + byte size once.
#     An unreadable path is reported and the record drops out of the queue
#     entirely (never counted as emitted, never fatal on its own).
#
#     content="$(cat "$p")" strips every trailing newline the source file
#     had (command substitution does this unconditionally) — deliberate:
#     it normalizes away each file's own trailing-newline convention so
#     $block has NO trailing newline of its own. The blank-line separator
#     between records is then added explicitly by the emission loop below,
#     via a plain printf (never through a $(...) capture, which would strip
#     it right back off). ---
declare -A BLOCK_BY_ID=()
declare -A SIZE_BY_ID=()
declare -A READABLE=()

for id in "${OUTPUT_QUEUE[@]}"; do
    p="${PATH_BY_ID[$id]}"
    if [ ! -f "$p" ] || [ ! -r "$p" ]; then
        printf '%s: unreadable path for record %s (%s): %s\n' "$prog" "${NUM_BY_ID[$id]:-?}" "$id" "$p" >&2
        continue
    fi
    content="$(cat "$p")"
    block="$(printf '===== RECORD %s %s (%s) =====\n%s' "${NUM_BY_ID[$id]:-?}" "$id" "$p" "$content")"
    BLOCK_BY_ID["$id"]="$block"
    SIZE_BY_ID["$id"]="$(printf '%s' "$block" | wc -c | tr -d ' ')"
    READABLE["$id"]=1
done

# --- budget: direct records take priority over link-expanded ones when
#     --max-bytes is tight (greedy accept in priority order; whatever is
#     accepted is still emitted in normal selection order below). ---
declare -A ACCEPTED=()
DROPPED_IDS=()
TOTAL_BYTES=0

if [ -n "$MAX_BYTES" ]; then
    PRIORITY_ORDER=()
    for id in "${OUTPUT_QUEUE[@]}"; do
        [ -n "${READABLE[$id]+x}" ] || continue
        [ -n "${IS_EXPANSION[$id]+x}" ] && continue
        PRIORITY_ORDER+=("$id")
    done
    for id in "${OUTPUT_QUEUE[@]}"; do
        [ -n "${READABLE[$id]+x}" ] || continue
        [ -n "${IS_EXPANSION[$id]+x}" ] || continue
        PRIORITY_ORDER+=("$id")
    done
    for id in "${PRIORITY_ORDER[@]}"; do
        sz="${SIZE_BY_ID[$id]}"
        if [ $((TOTAL_BYTES + sz)) -le "$MAX_BYTES" ]; then
            ACCEPTED["$id"]=1
            TOTAL_BYTES=$((TOTAL_BYTES + sz))
        else
            DROPPED_IDS+=("$id")
        fi
    done
    if [ "${#DROPPED_IDS[@]}" -gt 0 ]; then
        dropped_csv="$(IFS=,; echo "${DROPPED_IDS[*]}")"
        printf '%s: --max-bytes %s exceeded: dropped %d record(s): %s\n' \
            "$prog" "$MAX_BYTES" "${#DROPPED_IDS[@]}" "$dropped_csv" >&2
    fi
else
    for id in "${OUTPUT_QUEUE[@]}"; do
        [ -n "${READABLE[$id]+x}" ] || continue
        ACCEPTED["$id"]=1
        TOTAL_BYTES=$((TOTAL_BYTES + SIZE_BY_ID[$id]))
    done
fi

# --- emit: original selection order, a record's link-expansions
#     immediately after it (OUTPUT_QUEUE is already in exactly that order).
#     The blank-line separator is printed directly (not through a $(...)
#     capture) so it survives — see the note on $block construction above. ---
EMITTED_COUNT=0
LINK_EXPANDED_COUNT=0
FIRST_EMITTED=1
for id in "${OUTPUT_QUEUE[@]}"; do
    [ -n "${ACCEPTED[$id]+x}" ] || continue
    if [ "$FIRST_EMITTED" -eq 1 ]; then
        FIRST_EMITTED=0
    else
        printf '\n\n'
    fi
    printf '%s' "${BLOCK_BY_ID[$id]}"
    EMITTED_COUNT=$((EMITTED_COUNT + 1))
    [ -n "${IS_EXPANSION[$id]+x}" ] && LINK_EXPANDED_COUNT=$((LINK_EXPANDED_COUNT + 1))
done
[ "$EMITTED_COUNT" -gt 0 ] && printf '\n'

printf '%s: summary: requested=%d emitted=%d link_expanded=%d unresolvable=%d bytes=%d\n' \
    "$prog" "$REQUESTED_COUNT" "$EMITTED_COUNT" "$LINK_EXPANDED_COUNT" "$UNRESOLVED_COUNT" "$TOTAL_BYTES" >&2

if [ "$EMITTED_COUNT" -eq 0 ]; then
    die "nothing was emitted (every requested number/id was unresolvable, or --max-bytes dropped everything) — refusing to produce an empty compile"
fi
if [ "$STRICT" -eq 1 ] && [ "$UNRESOLVED_COUNT" -gt 0 ]; then
    printf '%s: --strict: %d unresolvable request(s)\n' "$prog" "$UNRESOLVED_COUNT" >&2
    exit 1
fi
exit 0
