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
#   --cat <path>...    ITS OWN MODE, and the batch-read surface: dump the FULL
#                      CONTENT of every record path named, in one call, behind
#                      the same `==> path <==` headers --full uses. Takes no
#                      query flags. Terminal — it consumes the rest of argv, so
#                      paths are never parsed as flags.
#                      --full dumps what a QUERY matched (count not chosen by
#                      the caller, so capped at FULL_CAP); --cat dumps what the
#                      CALLER named (already a deliberate selection, so
#                      uncapped). Use it after a gloss survey to read the
#                      records you picked — never a raw `awk`/`cat`, which can
#                      read outside the stores.
#                      Every path must be one the same scan could return; a
#                      path outside the stores, archived, or missing is exit 2
#                      with NOTHING dumped (a half-batch reads as a whole one).
#                      Paths, not ids — for an id use `--id <id> --full`.
#   --recall <toks>    field-anchored recall over mistakes.jsonl (its own mode;
#                      combine only with --limit). Tokens are matched against
#                      the VALUES of the semantic fields (pattern, description,
#                      correction, face, category, skill, summary, what, fix) —
#                      never keys, paths, URLs, or session ids, so a broad term
#                      set cannot return path-noise the way a raw `grep -i` of
#                      the file does. Output on a hit: a `recall: N matched`
#                      count line, then the most recent 20 matches (override
#                      with --limit; 0 = all). No match: empty stdout, exit 0,
#                      same as every other mode.
#                      Matcher: scripts/lib/recall-match.awk. File:
#                      $ROOT/mistakes.jsonl (env QUERY_RECORDS_RECALL_FILE).
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
#   2  usage error — unknown/repeated flag, bad --limit, no filter given, a
#      --keyword whose tokens were all dropped (nothing left to search), or a
#      --cat that named no path, combined with another mode, or named anything
#      the corpus scan would not return (missing, archived, outside the stores)
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
#   scripts/query-records.sh --cat references/decisions/a.md plans/b.md

set -uo pipefail

# Byte-safe text processing: one non-UTF-8 byte anywhere in the corpus makes
# BSD cut/grep abort under a UTF-8 locale ("Illegal byte sequence" on macOS).
export LC_ALL=C

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
# query-records uses ALL_STORES as its local name; queries also cover the
# vendor stores (titw-managed packages) and any env-configured extra stores —
# neither of which lint/backfill ever touch. The ${arr[@]+...} idiom keeps an
# empty EXTRA_STORES safe under `set -u` on bash 3.2 (macOS).
ALL_STORES=("${STORES[@]}" "${VENDOR_STORES[@]}" ${EXTRA_STORES[@]+"${EXTRA_STORES[@]}"})

# --list-stores: print the scan surface, one store per line, and exit. THE
# discovery mechanism — agents scope their searches to this output instead of
# a hand-maintained list in prose (owner call, 2026-08-09; supersedes the
# inlined-list convention the old store-list-drift guard existed to patrol).
if [ "${1:-}" = "--list-stores" ]; then
    printf '%s\n' "${ALL_STORES[@]}"
    exit 0
fi

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
Q_RECALL=""
Q_CAT=0
CAT_REFS=()

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
        --recall)    seen_once "$1"; Q_RECALL="${2:-}"; shift 2 ;;
        --limit)     seen_once "$1"; LIMIT="${2:-0}"; shift 2 ;;
        --full)      Q_FULL=1; shift ;;
        # --cat is TERMINAL: it consumes the rest of argv as record paths, so a
        # path is never mistaken for a flag. A flag typed after it is refused
        # rather than swallowed as a path — otherwise the error names a missing
        # record when the real mistake is that the modes cannot combine.
        --cat)
            seen_once "$1"; Q_CAT=1; shift
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --*) echo "query-records: --cat is its own mode — it takes record paths, and cannot be combined with $1" >&2; exit 2 ;;
                esac
                CAT_REFS+=("$1"); shift
            done
            ;;
        --rel-ratio) seen_once "$1"; REL_RATIO="${2:-}"; shift 2 ;;
        --k-floor)   seen_once "$1"; K_FLOOR="${2:-}"; shift 2 ;;
        *) echo "query-records: unknown flag: $1" >&2; exit 2 ;;
    esac
done
case "$LIMIT" in ''|*[!0-9]*) echo "query-records: --limit needs a non-negative integer (0 = uncapped)" >&2; exit 2 ;; esac

# --cat is a retrieval mode, not a filter — check it before the filter
# requirement below, which it would otherwise trip.
if [ "$Q_CAT" -eq 1 ]; then
    if [ -n "$Q_KEYWORD" ] || [ -n "$Q_KIND" ] || [ -n "$Q_ID" ] || [ -n "$Q_LINKS_TO" ] \
       || [ -n "$Q_RECALL" ] || [ "$Q_FULL" -eq 1 ]; then
        echo "query-records: --cat is its own mode — it dumps the records you name, so it takes no query flags" >&2
        exit 2
    fi
    case "$SEEN_FLAGS" in
        *" --limit "*)
            echo "query-records: --cat is its own mode — --limit caps a match set, and --cat has none" >&2
            exit 2 ;;
    esac
    if [ "${#CAT_REFS[@]}" -eq 0 ]; then
        # Not an empty success: "dumped nothing" and "you named nothing" must
        # not look alike, same contract as every other mode in this file.
        echo "query-records: --cat needs at least one record path (space-separated)." >&2
        exit 2
    fi
fi

if [ "$Q_CAT" -eq 0 ] && [ -z "$Q_KEYWORD" ] && [ -z "$Q_KIND" ] && [ -z "$Q_ID" ] && [ -z "$Q_LINKS_TO" ] && [ -z "$Q_RECALL" ]; then
    echo "query-records: need at least one of --keyword/--kind/--id/--links-to/--recall" >&2
    exit 2
fi

# ---- recall mode: field-anchored sweep over mistakes.jsonl ----
# PLUGIN ADAPTATION: recall has no upstream counterpart to vendor from —
# orchard-codex#268 phase 1 removed these scripts from the codex, making this
# plugin the source of truth for query-records machinery. The codex's own
# copy is a frozen older version that never covered mistakes.jsonl.
if [ -n "$Q_RECALL" ]; then
    if [ -n "$Q_KEYWORD" ] || [ -n "$Q_KIND" ] || [ -n "$Q_ID" ] || [ -n "$Q_LINKS_TO" ] || [ "$Q_FULL" -eq 1 ]; then
        echo "query-records: --recall is its own mode — combine only with --limit" >&2
        exit 2
    fi
    RECALL_FILE="${QUERY_RECORDS_RECALL_FILE:-$ROOT/mistakes.jsonl}"
    if [ ! -f "$RECALL_FILE" ]; then
        # Same contract as exit 3 elsewhere: "no store" must not read as "no
        # matches".
        echo "query-records: recall store not found: $RECALL_FILE — NOT 'no matches'" >&2
        exit 3
    fi
    # Recall tokenization differs from --keyword: whitespace separates TERMS,
    # and punctuation inside a term is kept as a phrase joint ("pickup-loop"
    # matches the phrase "pickup loop"/"pickup-loop", never bare "loop").
    # Splitting phrases into independent tokens made a broad term set match
    # most of the file — common words like "type" hit everywhere.
    TOKEN_FILE="$(mktemp)"
    trap 'rm -f "$TOKEN_FILE"' EXIT
    printf '%s' "$Q_RECALL" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -s '[:space:]' '\n' \
        | awk -v min="$MIN_TOKEN_LEN" '{ s = $0; gsub(/[^a-z0-9]/, "", s); if (length(s) >= min) print }' \
        | sort -u > "$TOKEN_FILE"
    if [ ! -s "$TOKEN_FILE" ]; then
        echo "query-records: --recall \"$Q_RECALL\" has no token of $MIN_TOKEN_LEN+ characters — nothing to search." >&2
        echo "query-records: this is NOT 'no matches'. Tokens shorter than $MIN_TOKEN_LEN characters are dropped; use a longer term." >&2
        exit 2
    fi
    if ! HITS="$(awk -v tokfile="$TOKEN_FILE" -f "$LIB_DIR/recall-match.awk" "$RECALL_FILE")"; then
        echo "query-records: recall scan failed (awk unusable or lib missing) — NOT 'no matches'" >&2
        exit 3
    fi
    [ -z "$HITS" ] && exit 0
    TOTAL="$(printf '%s\n' "$HITS" | grep -c .)"
    # Default cap 20 (most recent — file order is chronological); an explicit
    # --limit overrides, 0 = uncapped. The count line always prints, so a cap
    # can never be silent.
    RECALL_CAP=20
    case "$SEEN_FLAGS" in *" --limit "*) RECALL_CAP="$LIMIT" ;; esac
    if [ "$RECALL_CAP" -gt 0 ] && [ "$TOTAL" -gt "$RECALL_CAP" ]; then
        printf 'recall: %d matched — showing the %d most recent (raise --limit for more)\n' "$TOTAL" "$RECALL_CAP"
        printf '%s\n' "$HITS" | tail -n "$RECALL_CAP"
    else
        printf 'recall: %d matched\n' "$TOTAL"
        printf '%s\n' "$HITS"
    fi
    exit 0
fi

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
        printf '(--full: dumped %d of %d matched records — narrow the query, or read the rest with: --cat <paths>)\n' \
            "$FULL_CAP" "$total"
    fi
}

# ---- candidate corpus (all stores, excluding INDEX.md and archived) ----
ALL_FILES="$(for d in "${ALL_STORES[@]}"; do
    [ -d "$d" ] || continue
    find -H "$d" -type f -name '*.md' ! -name 'INDEX.md' ! -path '*_archived*'
done | sort)"

# ---- --cat mode: dump an EXPLICIT list of records, in one call ----
# PLUGIN ADAPTATION: --cat has no upstream counterpart to vendor from —
# orchard-codex#268 phase 1 removed these scripts from the codex, making this
# plugin the source of truth for query-records machinery. Same class as
# --recall below.
#
# The scout's flow is survey-then-select: it runs several gloss queries and
# picks a union of paths across them. No single query matches that union, so
# --full cannot serve it, and the raw `awk 'FNR==1{...}'` batch-read it used to
# fall back to is a second retrieval surface — one that reads anywhere on disk.
#
# In-bounds is defined as membership in ALL_FILES, the very set a query can
# return. That is why the check is a lookup and not path canonicalization:
# `pwd -P` would resolve the titw store's symlink and reject a legitimate
# vendored record.
#
# UNCAPPED, unlike --full: a --full match count is not something the caller
# sized, but a --cat list is the caller's own selection. Capping it would send
# the scout straight back to the raw awk this flag exists to remove.
if [ "$Q_CAT" -eq 1 ]; then
    CAT_RESOLVED=""
    CAT_BAD=""
    CAT_IDLIKE=0
    # Membership is a pure-bash pattern match against a newline-delimited copy
    # of the corpus, built ONCE. It is deliberately not `... | grep -qxF`.
    #
    # This script runs under `set -uo pipefail` (line 103). `grep -q` exits the
    # instant it matches, which closes the pipe while the writer is still
    # writing, so the writer dies of SIGPIPE and pipefail hands the PIPELINE
    # status 141 — on SUCCESS. Every real match read as "not a record", and
    # --cat refused the survey's own paths.
    #
    # It passed 25 tests because the failure is input-size dependent: a fixture
    # corpus (~100 bytes) fits one atomic write, so the writer finishes before
    # grep exits and no SIGPIPE happens. The live corpus is ~1,800 paths (~80KB)
    # and never fits. Fixtures could not have caught this; the round-trip test
    # below runs against a corpus larger than the pipe buffer for that reason.
    #
    # "$norm" is QUOTED inside the case pattern, making it literal — an unquoted
    # expansion would let a ref like 'references/*' glob-match the corpus.
    CAT_HAYSTACK=$'\n'"$ALL_FILES"$'\n'
    # The documented loop is "pipe the survey's paths straight back in":
    #   p=$(query-records.sh --keyword X | awk -F' — ' '{print $1}')
    #   query-records.sh --cat $p
    # bash word-splits that unquoted expansion on IFS (which includes newline),
    # so --cat receives one argv word per path. zsh does NOT split unquoted
    # expansions, so the SAME command hands --cat a single word containing
    # newlines. Refusing it made the shipped loop shell-dependent — it worked
    # under bash and failed under zsh, which is the shell this runs in.
    #
    # So a newline-bearing word is expanded into the newline-separated list the
    # caller plainly meant. This does NOT loosen the smuggling guard: every
    # element produced here goes through the same membership check below, so
    # nothing unvalidated can reach print_full's `tr '\n' '\0'`. A smuggled
    # non-record still lands in CAT_BAD and still aborts the whole batch.
    CAT_EXPANDED=()
    for ref in ${CAT_REFS[@]+"${CAT_REFS[@]}"}; do
        case "$ref" in
            *$'\n'*)
                while IFS= read -r part; do
                    # Empty elements here are separator artifacts (a trailing
                    # newline), not a caller naming an empty path. An explicitly
                    # empty argument still reaches the else-branch and is named.
                    [ -n "$part" ] || continue
                    CAT_EXPANDED+=("$part")
                done <<< "$ref"
                ;;
            *) CAT_EXPANDED+=("$ref") ;;
        esac
    done
    # A word that was nothing but separators leaves no paths behind; that is a
    # bad reference, not an empty batch that should silently succeed.
    [ "${#CAT_EXPANDED[@]}" -eq 0 ] && CAT_EXPANDED=("")
    for ref in ${CAT_EXPANDED[@]+"${CAT_EXPANDED[@]}"}; do
        norm="${ref#./}"
        case "$norm" in
            /*) norm="${norm#"$ROOT"/}" ;;
        esac
        # A newline inside a ref would smuggle a SECOND path past the check
        # below: grep -F reads a multi-line pattern as several patterns, so a
        # ref whose first line is a real record matches, and the dump then
        # splits the same string back into two filenames — the second one
        # never checked. No record path contains a newline; refuse outright.
        case "$norm" in
            *$'\n'*|"") norm="" ;;
        esac
        CAT_HIT=0
        if [ -n "$norm" ]; then
            case "$CAT_HAYSTACK" in
                *$'\n'"$norm"$'\n'*) CAT_HIT=1 ;;
            esac
        fi
        if [ "$CAT_HIT" -eq 1 ]; then
            CAT_RESOLVED="$CAT_RESOLVED$norm
"
        else
            # Name the empty ref rather than printing a blank line for it.
            CAT_BAD="$CAT_BAD${ref:-(empty)}
"
            case "$ref" in
                */*|*.md) ;;
                *.*) CAT_IDLIKE=1 ;;
            esac
        fi
    done
    # Dedupe last, preserving the caller's order: a record picked up by two
    # surveys must not be paid for twice.
    CAT_RESOLVED="$(printf '%s' "$CAT_RESOLVED" | awk 'NF && !seen[$0]++')"
    if [ -n "$CAT_BAD" ]; then
        # ATOMIC: dump nothing. A half-delivered batch is the dangerous shape —
        # the caller believes it read everything it selected.
        printf '%s' "$CAT_BAD" | while IFS= read -r b; do
            [ -n "$b" ] || continue
            echo "query-records: --cat: not a record in the scanned stores: $b" >&2
        done
        echo "query-records: --cat reads only records the same scan returns (see --list-stores); nothing was dumped." >&2
        [ "$CAT_IDLIKE" -eq 1 ] && \
            echo "query-records: --cat takes record PATHS. To fetch by record id, use: --id <id> --full" >&2
        exit 2
    fi
    printf '%s\n' "$CAT_RESOLVED" | print_full
    exit 0
fi

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
