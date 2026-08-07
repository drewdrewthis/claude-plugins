#!/usr/bin/env bash
# query-records.sh — canonical PULL interface over the codex record stores.
#
# On-demand query tool for the corpus, used when an agent or human wants to
# look something up deliberately (a prior decision, every record linking an
# id, all procedures of a kind) — directly, or via `procedure-scout`
# (dispatched by `Skill(how-do-i)`, gated in front of every main-agent turn by
# hooks/how-do-i-gate.sh). Matcher: scripts/lib/record-match.awk.
#
# Covers ALL SEVEN record stores (the original four plus research, plans,
# principles).
#
# Flags (combine with AND logic — every condition must hold). Each flag may be
# given AT MOST ONCE; repeating one is a usage error (exit 2), not a silent
# last-wins overwrite. To search several terms, put them in ONE --keyword
# string — they are tokenized into a ranked OR union:
#   --keyword "recall fts5 benchmark"        # one union query, correct
#   --keyword recall --keyword benchmark     # exit 2, not "benchmark only"
#   --keyword <toks>   records whose frontmatter `keywords` contain any token.
#                      Tokens shorter than MIN_TOKEN_LEN (2) are dropped; if
#                      that leaves nothing to search (e.g. --keyword "a b"),
#                      the script exits 2 rather than returning an empty
#                      result that reads as "searched, found nothing".
#                      2-char terms ARE searchable here (`pr`, `ci`, `gh`) even
#                      though the PUSH router ignores them as prompt noise.
#   --kind <kind>      records whose frontmatter `kind:` equals <kind>.
#   --id <id>          the record whose frontmatter `id:` equals <id> exactly.
#   --links-to <id>    records whose `links:` value references <id>.
#   --limit <N>        cap the total result count (env QUERY_RECORDS_LIMIT).
#                      0/absent = all matches (the default).
#   --full             after the match list, print the FULL CONTENT of every
#                      matched record, separated by `==> path <==` headers —
#                      one call returns everything a reader needs (frontmatter
#                      incl. status/enforced_by, body, all sections), instead
#                      of forcing a follow-up read per file. Dumped records are
#                      capped at FULL_CAP (10), regardless of --limit; beyond
#                      that, a `(--full: dumped N of M matched records — ...)`
#                      notice line is printed instead of silently truncating.
#                      Piping --full to a truncating consumer (head/less-q) may
#                      print a benign `xargs: awk: terminated by signal 13` on
#                      stderr (SIGPIPE); stdout is unaffected.
#   --rel-ratio <X>    matcher's relative floor, within a kind bucket a
#                      candidate scoring < X * (bucket top score) is dropped
#                      (env QUERY_RECORDS_REL_RATIO). 0 disables this
#                      suppression. Default 0.3 (unchanged ranking behavior).
#   --k-floor <N>      matcher's rarity-gate document-frequency threshold
#                      (env QUERY_RECORDS_K_FLOOR). Default 2 (unchanged).
#
# PLUGIN ADAPTATION: owner call — a query returns ALL matches by default;
# truncation and ranking floors are opt-in knobs, because the scout needs the
# full match set.
#
# Output: `path — gloss` lines (same shape as the router). All matches by
# default; pass --limit to cap. No match: empty stdout, exit 0.
#
# Exit codes — a caller MUST be able to tell "searched, found nothing" from
# "never searched", because both otherwise look like empty stdout:
#   0  the query ran; empty stdout means a genuine miss
#   2  usage error — unknown/repeated flag, bad --limit, no filter given, or a
#      --keyword whose tokens were all dropped (nothing left to search)
#   3  scan failed (awk unusable or lib missing) — NOT 'no matches'
#
# Pure bash/grep/awk; no network, no LLM.
#
# Usage:
#   scripts/query-records.sh --keyword autonomy
#   scripts/query-records.sh --kind procedure
#   scripts/query-records.sh --id dec.2026-06-12-skill-is-invokable-procedure
#   scripts/query-records.sh --links-to fm.unverified-claim-acted-on
#   scripts/query-records.sh --kind solution --keyword autonomy   # AND
#   scripts/query-records.sh --keyword gitflow --full --limit 5

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared awk libs live next to this script (scripts/lib) — resolved against the
# REAL script location, independent of the corpus root override below.
LIB_DIR="$SCRIPT_DIR/lib"
# ROOT (the corpus root) defaults to repo root. Overridable via
# QUERY_RECORDS_ROOT for testing against fixture stores.
# PLUGIN ADAPTATION: data root defaults to the host codex (~/.claude), not this
# plugin install dir — upstream these scripts live inside the codex repo itself.
ROOT="${QUERY_RECORDS_ROOT:-${CODEX_ROOT:-$HOME/.claude}}"
cd "$ROOT" || exit 0

# SSOT store list — sourced from scripts/lib/stores.sh (defines STORES array).
# shellcheck source=scripts/lib/stores.sh
source "$SCRIPT_DIR/lib/stores.sh"
# query-records uses ALL_STORES as its local name; alias for clarity.
ALL_STORES=("${STORES[@]}")

# PLUGIN ADAPTATION: owner call — a query returns ALL matches by default;
# truncation and ranking floors are opt-in knobs, because the scout needs the
# full match set. LIMIT=0 means uncapped (total-result cap, applied below);
# upstream defaults to 20 and passes it to the matcher as a per-kind cap.
LIMIT="${QUERY_RECORDS_LIMIT:-0}"
FULL_CAP=10
# PLUGIN ADAPTATION: the PULL path indexes 2-char keyword tokens; the PUSH
# router keeps its 3-char floor. Same reasoning as gate=0 below — an explicit
# --keyword is a term the caller chose, not prompt noise to be filtered. At 3,
# `pr` (135 keyword slots in the live corpus), `ci` (29) and `gh` (16) were
# unmatchable: `--keyword pr` could never reach pr-review or pr-ready-check.
# Passed to record-match.awk AND record-rarity.awk — they must agree, or df/idf
# is computed over a different token set than the one scored.
MIN_TOKEN_LEN=2
REL_RATIO="${QUERY_RECORDS_REL_RATIO:-}"
K_FLOOR="${QUERY_RECORDS_K_FLOOR:-}"

# ---- parse flags ----
Q_KEYWORD=""
Q_KIND=""
Q_ID=""
Q_LINKS_TO=""
Q_FULL=0

# PLUGIN ADAPTATION: upstream silently keeps the last occurrence of a repeated
# flag. For a discovery tool a confident wrong answer is worse than an error, so
# this copy refuses instead.
# Repeating a value-taking flag used to silently keep the last occurrence, so
# `--keyword recall --keyword gitflow` returned gitflow-only results at full
# speed with no warning — a confidently wrong answer, which for a discovery
# tool is worse than an error. SEEN_FLAGS records which flags have been
# consumed so a repeat can be refused. --full is idempotent and exempt.
SEEN_FLAGS=" "
seen_once() {
    case "$SEEN_FLAGS" in
        *" $1 "*)
            echo "query-records: $1 given more than once — each flag may appear at most once." >&2
            if [ "$1" = "--keyword" ]; then
                echo "query-records: to search several terms, put them in ONE string: --keyword \"term1 term2\" (ranked OR union)." >&2
            fi
            exit 2
            ;;
    esac
    SEEN_FLAGS="$SEEN_FLAGS$1 "
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --keyword)   seen_once "$1"; Q_KEYWORD="${2:-}"; shift 2 ;;
        --kind)      seen_once "$1"; Q_KIND="${2:-}"; shift 2 ;;
        --id)        seen_once "$1"; Q_ID="${2:-}"; shift 2 ;;
        --links-to)  seen_once "$1"; Q_LINKS_TO="${2:-}"; shift 2 ;;
        --limit)     seen_once "$1"; LIMIT="${2:-0}"; shift 2 ;;
        --full)      Q_FULL=1; shift ;;
        --rel-ratio) seen_once "$1"; REL_RATIO="${2:-}"; shift 2 ;;
        --k-floor)   seen_once "$1"; K_FLOOR="${2:-}"; shift 2 ;;
        *) echo "query-records: unknown flag: $1" >&2; exit 2 ;;
    esac
done
case "$LIMIT" in ''|*[!0-9]*) echo "query-records: --limit needs a non-negative integer (0 = uncapped)" >&2; exit 2 ;; esac

if [ -z "$Q_KEYWORD" ] && [ -z "$Q_KIND" ] && [ -z "$Q_ID" ] && [ -z "$Q_LINKS_TO" ]; then
    echo "query-records: need at least one of --keyword/--kind/--id/--links-to" >&2
    exit 2
fi

# ---- candidate corpus (all stores, excluding INDEX.md and archived) ----
ALL_FILES="$(for d in "${ALL_STORES[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -type f -name '*.md' ! -name 'INDEX.md' ! -path '*_archived*'
done | sort)"
[ -z "$ALL_FILES" ] && exit 0

# ---- structural filters (kind / id / links-to): ONE awk pass over the corpus
# record-scan.awk parses each file's frontmatter + gloss and applies the
# filters in-process — replaces the previous per-file fork loop (~2 forks per
# file per queried key, ~2-5s over the live corpus; now one process, <0.5s).
# Emits `path \t gloss` for every passing file.
# PLUGIN ADAPTATION: fail loud, not silently-empty — plugin runs on arbitrary
# hosts whose awk may lack nextfile.
if ! SCANNED="$(printf '%s\n' "$ALL_FILES" | tr '\n' '\0' \
    | xargs -0 awk -v qkind="$Q_KIND" -v qid="$Q_ID" -v qlinks="$Q_LINKS_TO" \
        -f "$LIB_DIR/record-scan.awk")"; then
    echo "query-records: record scan failed (awk unusable or lib missing) — NOT 'no matches'" >&2
    exit 3
fi
[ -z "$SCANNED" ] && exit 0
NARROWED="$(printf '%s\n' "$SCANNED" | cut -f1)"

# print_full <paths on stdin> — dump each record in full with a path header.
print_full() {
    tr '\n' '\0' | xargs -0 awk '
        FNR==1 { printf "\n==> %s <==\n", FILENAME }
        { print }
    '
}

# print_full_capped <paths on stdin> — dump at most FULL_CAP records via
# print_full; if more paths were matched, append one truncation notice
# instead of silently dumping the rest (context-bomb guard).
print_full_capped() {
    local paths total
    paths="$(cat)"
    total="$(printf '%s\n' "$paths" | grep -c .)"
    printf '%s\n' "$paths" | head -n "$FULL_CAP" | print_full
    if [ "$total" -gt "$FULL_CAP" ]; then
        printf '(--full: dumped %d of %d matched records — narrow the query, or batch-read the rest with: awk '"'"'FNR==1{print "==> " FILENAME " <=="}1'"'"' <paths>)\n' \
            "$FULL_CAP" "$total"
    fi
}

# ---- keyword path: hand the narrowed set to the SHARED matcher ----
if [ -n "$Q_KEYWORD" ]; then
    # tokenize the keyword the same way the router tokenizes its prompt.
    TOKEN_FILE="$(mktemp)"
    IDF_FILE="$(mktemp)"
    trap 'rm -f "$TOKEN_FILE" "$IDF_FILE"' EXIT
    printf '%s' "$Q_KEYWORD" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '\n' \
        | awk -v min="$MIN_TOKEN_LEN" 'length($0) >= min' \
        | sort -u > "$TOKEN_FILE"
    if [ ! -s "$TOKEN_FILE" ]; then
        # PLUGIN ADAPTATION: upstream exits 0 here, which a caller cannot tell
        # apart from a genuine miss. This copy fails loud, matching the exit-3
        # scan-error path already in this file.
        # Every token fell under MIN_TOKEN_LEN, so no search ran at all. Exiting
        # 0 here made that indistinguishable from a genuine miss — the caller
        # concluded "the corpus has nothing" when nothing was ever queried.
        # Real shapes that hit this: --keyword ci / pr / gh / db.
        echo "query-records: --keyword \"$Q_KEYWORD\" has no token of $MIN_TOKEN_LEN+ characters — nothing to search." >&2
        echo "query-records: this is NOT 'no matches'. Tokens shorter than $MIN_TOKEN_LEN characters are dropped; use a longer term." >&2
        exit 2
    fi
    # IDF pre-pass over the narrowed set, shared lib (df + idf + corpus stats).
    printf '%s\n' "$NARROWED" | awk -v min_tok="$MIN_TOKEN_LEN" \
        -f "$LIB_DIR/record-rarity.awk" > "$IDF_FILE"
    # The PULL path is deliberately permissive: an explicit single-token query
    # (e.g. --keyword issue) must still surface that token's records even though
    # the PUSH gate would suppress a lone common token. So pass gate=0 to turn
    # OFF the absolute df<=K_floor floor — the matcher then ranks every record
    # with >=1 matched token and returns the top-N. The router keeps gate=1.
    # PLUGIN ADAPTATION: owner call — the matcher's own per-kind `limit` stays
    # uncapped (0) here; the total-result cap (--limit/QUERY_RECORDS_LIMIT) is
    # applied uniformly below, after this path and the structural-only path
    # both emit their full match sets.
    MATCH_OUT="$(printf '%s\n' "$NARROWED" | awk \
        -v tokfile="$TOKEN_FILE" \
        -v idffile="$IDF_FILE" \
        -v gate=0 \
        -v limit=0 \
        -v rel_ratio="$REL_RATIO" \
        -v k_floor="$K_FLOOR" \
        -v min_tok="$MIN_TOKEN_LEN" \
        -f "$LIB_DIR/record-match.awk")"
    if [ "$LIMIT" -gt 0 ]; then
        MATCHED="$(printf '%s\n' "$MATCH_OUT" | head -n "$LIMIT")"
    else
        MATCHED="$MATCH_OUT"
    fi
    [ -z "$MATCHED" ] && exit 0
    printf '%s\n' "$MATCHED"
    if [ "$Q_FULL" -eq 1 ]; then
        printf '%s\n' "$MATCHED" | sed 's/ — .*//' | print_full_capped
    fi
    exit 0
fi

# ---- no keyword: emit the structurally-narrowed records as path — gloss ----
# PLUGIN ADAPTATION: owner call — all matches by default, so the cap is applied
# only when LIMIT>0 (upstream always caps: `head -n "$LIMIT"` with LIMIT=20 by
# default, where `head -n 0` would emit nothing).
if [ "$LIMIT" -gt 0 ]; then
    SCANNED="$(printf '%s\n' "$SCANNED" | head -n "$LIMIT")"
fi
MATCHED="$(printf '%s\n' "$SCANNED" | awk -F'\t' '{ printf "%s — %s\n", $1, $2 }')"
printf '%s\n' "$MATCHED"
if [ "$Q_FULL" -eq 1 ]; then
    printf '%s\n' "$MATCHED" | sed 's/ — .*//' | print_full_capped
fi

exit 0
