#!/usr/bin/env bash
# build-record-index.sh — numbered record index for integer-based selection.
#
# A model asked to pick a record by id string fabricates ids (recombines real
# id fragments) under load. Asked to pick by integer, fabrication is
# structurally impossible: an out-of-range or non-numeric answer is trivially
# rejected by the caller. This script builds that numbering.
#
# Usage: build-record-index.sh --out DIR [--root PATH] [--strict]
#
#   --out DIR    Required. index.txt and map.tsv are written into DIR
#                (created with mkdir -p if missing).
#   --root PATH  Single corpus root — overrides multi-root entirely (see
#                below). Tests MUST pass --root at a fixture dir, never the
#                real corpus.
#   --strict     Exit non-zero if any file was skipped for a missing id
#                and/or description, or had unparseable frontmatter — even
#                though the (partial) index is still written.
#
# Roots: with --root, exactly that one directory is scanned (100% of this
# script's original, single-root contract). Without --root, the roots come
# from CODEX_STORE_ROOTS (colon-separated, see lib/stores.sh for the full
# precedence chain); if nothing resolves at any tier, the script errors
# (no hardcoded default). A configured root that does not exist is skipped
# with a stderr warning, not a hard failure.
#
# Outputs (exactly two files, both inside --out DIR, merged across every
# root):
#   index.txt  One line per record: "N :: description". N is a 1-based
#              integer assigned in id-sorted order across ALL roots. No
#              paths, no ids, no header, no banner — this file is fed
#              verbatim to a model and every byte is prompt cost.
#   map.tsv    One line per record, tab-separated: "N<TAB>id<TAB>path". Same
#              N, same order as index.txt. path is absolute. Lookup table to
#              resolve a model's chosen integer back to a real file.
# Additionally, for each root, a browsing-convenience index.txt (same "N ::
# description" shape, LOCALLY numbered 1..N for that root alone) is written
# to <root>/.index/index.txt. Best-effort: a root that cannot be written to
# just does not get this file, without failing the run.
#
# Discovery: scans <root>/references/** and <root>/plans/** for *.md, per
# root, via lib/stores.sh's _stores_discover() (never a hardcoded store
# list).
#
# Excluded unconditionally:
#   - any path containing /node_modules/
#   - files named EVOLUTION.md or INDEX.md
#   - any file whose FRONTMATTER BLOCK (not body) contains a user-invocable:
#     key — these are command files (skills/steps), not records
#   - <root>/references/plans/ — a stale duplicate of the live <root>/plans/
#
# Included only if frontmatter has both a non-empty id: and a non-empty
# description:. description is normalized (interior whitespace collapsed to
# single spaces, trimmed) so a tab or an accidental multi-line value can
# never corrupt map.tsv's column count or index.txt's one-line-per-record
# shape. An id that collides across two roots aborts the run (lists both
# paths) — same-root duplicates are a lint-frontmatter.sh concern, not this
# script's.
#
# Loud failure, always to stderr (stdout stays clean — it is not this
# script's product, the two files are):
#   - count of files with an id but no description
#   - count of files with a description but no id
#   - count of files whose frontmatter could not be parsed (no opening ---,
#     or an opening --- that never closes)
#   - a one-line summary: total indexed, per-store breakdown
#   (all three counts are summed across every root)
#   A file whose closed frontmatter has NEITHER id nor description is not a
#   record-shaped file at all (e.g. a policy doc with title:/purpose: keys);
#   it is skipped silently, incrementing none of the three counters above.
#
# Exit codes: 0 success. 1 zero records indexed overall, a cross-root id
# collision, an internal scan failure, or (--strict) a nonzero skip count.
# 2 usage error / no valid root.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

usage() {
    cat <<'EOF'
Usage: build-record-index.sh --out DIR [--root PATH] [--strict]

  --out DIR    Required. index.txt and map.tsv are written into DIR.
  --root PATH  Single corpus root, overriding multi-root. Without this,
               roots come from CODEX_STORE_ROOTS (colon-separated, see
               lib/stores.sh for full precedence); if nothing resolves,
               the script errors.
  --strict     Exit non-zero if any file was skipped (missing id/description,
               or unparseable frontmatter).
EOF
}

OUT_DIR=""
ROOT="${CODEX_ROOT:-}"
ROOT_EXPLICIT=0
STRICT=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)
            if [ "$#" -lt 2 ]; then
                echo "build-record-index: --out requires a value" >&2
                exit 2
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        --root)
            if [ "$#" -lt 2 ]; then
                echo "build-record-index: --root requires a value" >&2
                exit 2
            fi
            ROOT="$2"
            ROOT_EXPLICIT=1
            shift 2
            ;;
        --strict)
            STRICT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "build-record-index: unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
    esac
done

if [ -z "$OUT_DIR" ]; then
    echo "build-record-index: --out is required (see --help)" >&2
    exit 2
fi
if [ "$ROOT_EXPLICIT" -eq 1 ] && { [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; }; then
    echo "build-record-index: --root not found or not a directory: $ROOT" >&2
    exit 2
fi
if [ ! -f "$LIB_DIR/stores.sh" ]; then
    echo "build-record-index: lib missing: $LIB_DIR/stores.sh" >&2
    exit 1
fi

# Resolve --out to an absolute path from the CALLER's cwd, before this
# script cd's into any root below (a relative --out would otherwise silently
# resolve against the last-visited root instead).
mkdir -p "$OUT_DIR" || { echo "build-record-index: cannot create --out directory: $OUT_DIR" >&2; exit 2; }
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# shellcheck source=lib/stores.sh
source "$LIB_DIR/stores.sh"

# Resolve the root list. --root wins outright (single root, byte-identical
# to this script's original contract — every existing test uses this path).
# Otherwise _stores_resolve_roots_spec (CODEX_STORE_ROOTS > settings.json >
# ~/.knowledge tiers > CODEX_ROOT — see lib/stores.sh), so this always
# matches what how-do-i.sh's roots.stamp records. When that resolver comes
# back empty (nothing resolved at ANY tier), we error rather than defaulting.
ROOTS=()
if [ "$ROOT_EXPLICIT" -eq 1 ]; then
    ROOT="$(cd "$ROOT" && pwd)"
    ROOTS=("$ROOT")
else
    _spec="$(_stores_resolve_roots_spec)"
    if [ -z "$_spec" ]; then
        _stores_no_roots_message >&2
        exit 2
    fi
    _stores_split_roots "$_spec"
    for _r in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
        if [ -d "$_r" ]; then
            ROOTS+=("$(cd "$_r" && pwd)")
        else
            echo "build-record-index: root not found, skipping: $_r" >&2
        fi
    done
    unset _r
fi
if [ "${#ROOTS[@]}" -eq 0 ]; then
    echo "build-record-index: no valid root directory found (checked: $(_stores_resolve_roots_spec))" >&2
    exit 2
fi

# AWK frontmatter scanner, written once and reused per root.
MAIN_AWK_FILE="$(mktemp)"
trap 'rm -f "$MAIN_AWK_FILE"' EXIT
cat > "$MAIN_AWK_FILE" <<'AWKPROG'
# Unquote one frontmatter scalar value: strips a single matching outer
# quote pair (double or single). Values shorter than 2 chars cannot carry
# a quote pair.
function stripq(v,   n) {
    n = length(v)
    if (n < 2) return v
    if (substr(v, 1, 1) == "\"" && substr(v, n, 1) == "\"") return substr(v, 2, n - 2)
    if (substr(v, 1, 1) == "'"  && substr(v, n, 1) == "'")  return substr(v, 2, n - 2)
    return v
}

FNR == 1 {
    if (NR > 1) finish()
    fpath = FILENAME
    infm = 0
    closed = 0
    id = ""
    desc = ""
    indesc = 0
    userinv = 0
    if ($0 == "---") { infm = 1; next }
    nextfile
}

infm == 1 && $0 == "---" {
    infm = 0
    closed = 1
    nextfile
}

infm == 1 && /^user-invocable:/ {
    userinv = 1
    indesc = 0
    next
}

infm == 1 && /^id:/ {
    v = $0
    sub(/^id:[[:space:]]*/, "", v)
    sub(/[[:space:]].*$/, "", v)
    id = stripq(v)
    indesc = 0
    next
}

infm == 1 && /^description:/ {
    v = $0
    sub(/^description:[[:space:]]*/, "", v)
    desc = v
    indesc = 1
    next
}

infm == 1 && /^[A-Za-z_][A-Za-z0-9_-]*:/ {
    indesc = 0
    next
}

infm == 1 && indesc == 1 {
    cont = $0
    sub(/^[[:space:]]+/, "", cont)
    if (cont != "") desc = desc " " cont
    next
}

infm == 1 { next }

END {
    if (NR > 0) finish()
    printf "STATS\t%d\t%d\t%d\n", id_no_desc, desc_no_id, unparsed
}

function finish(   d) {
    if (closed != 1) { unparsed++; return }
    if (userinv == 1) return
    d = normdesc(stripq(desc))
    if (id != "" && d != "") {
        printf "REC\t%s\t%s\t%s\n", fpath, id, d
    } else if (id != "" && d == "") {
        id_no_desc++
    } else if (id == "" && d != "") {
        desc_no_id++
    }
    # else: neither id nor description present -- not a record-shaped file,
    # skipped silently (not counted -- it never claimed to be a record).
}

function normdesc(s) {
    gsub(/[\t\r\n]/, " ", s)
    gsub(/[[:space:]]+/, " ", s)
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}
AWKPROG

ID_NO_DESC=0
DESC_NO_ID=0
UNPARSED=0
ALL_RECS=""   # global accumulator across every root: abspath \t relpath \t id \t desc

for ROOT_I in "${ROOTS[@]}"; do
    cd "$ROOT_I" || { echo "build-record-index: cannot cd to root: $ROOT_I -- skipping" >&2; continue; }
    _stores_discover

    if [ "${#STORES[@]}" -eq 0 ]; then
        echo "build-record-index: zero stores discovered under $ROOT_I -- skipping this root" >&2
        continue
    fi

    # references/plans is a stale nested directory; the live plans store is
    # the top-level plans/ (also in STORES). Dropped here, without editing
    # stores.sh.
    CANDIDATE_STORES=()
    for s in "${STORES[@]}"; do
        [ "$s" = "references/plans" ] && continue
        CANDIDATE_STORES+=("$s")
    done

    ROOT_FILES=""
    for s in ${CANDIDATE_STORES[@]+"${CANDIDATE_STORES[@]}"}; do
        [ -d "$s" ] || continue
        found="$(find "$s" -type f -name '*.md' \
                    ! -path '*/node_modules/*' \
                    ! -name 'EVOLUTION.md' \
                    ! -name 'INDEX.md')"
        [ -n "$found" ] && ROOT_FILES="${ROOT_FILES}${found}
"
    done
    ROOT_FILES="$(printf '%s' "$ROOT_FILES" | sort)"

    ROOT_RECS=""
    if [ -n "$ROOT_FILES" ]; then
        if ! SCAN_OUT="$(printf '%s\n' "$ROOT_FILES" | tr '\n' '\0' | xargs -0 awk -f "$MAIN_AWK_FILE")"; then
            echo "build-record-index: record scan failed (awk unusable) for root $ROOT_I -- NOT 'zero records'" >&2
            exit 1
        fi

        ROOT_RECS="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1 == "REC"')"
        STATS_LINE="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1 == "STATS"')"

        if [ -z "$STATS_LINE" ]; then
            echo "build-record-index: internal error -- scan produced no STATS line for root $ROOT_I" >&2
            exit 1
        fi
        r_id_no_desc="$(printf '%s\n' "$STATS_LINE" | cut -f2)"
        r_desc_no_id="$(printf '%s\n' "$STATS_LINE" | cut -f3)"
        r_unparsed="$(printf '%s\n' "$STATS_LINE" | cut -f4)"
        ID_NO_DESC=$((ID_NO_DESC + r_id_no_desc))
        DESC_NO_ID=$((DESC_NO_ID + r_desc_no_id))
        UNPARSED=$((UNPARSED + r_unparsed))
    fi

    if [ -n "$ROOT_RECS" ]; then
        # Per-root local index.txt (by-need browsing), numbered 1..N within
        # this root alone. Best-effort: never fails the run.
        ROOT_SORTED="$(printf '%s\n' "$ROOT_RECS" | cut -f2- | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k1,1)"
        if mkdir -p "$ROOT_I/.index" 2>/dev/null; then
            : > "$ROOT_I/.index/index.txt"
            rn=0
            while IFS="$(printf '\t')" read -r rpath _rid rdesc; do
                [ -n "$rpath" ] || continue
                rn=$((rn + 1))
                printf '%d :: %s\n' "$rn" "$rdesc" >> "$ROOT_I/.index/index.txt"
            done <<< "$ROOT_SORTED"
        fi

        # Fold into the global accumulator, path made absolute.
        ROOT_RECS_ABS="$(printf '%s\n' "$ROOT_RECS" | awk -F'\t' -v root="$ROOT_I" 'BEGIN{OFS="\t"} { print root "/" $2, $2, $3, $4 }')"
        ALL_RECS="${ALL_RECS}${ROOT_RECS_ABS}
"
    fi
done

echo "build-record-index: $ID_NO_DESC file(s) have an id but no description" >&2
echo "build-record-index: $DESC_NO_ID file(s) have a description but no id" >&2
echo "build-record-index: $UNPARSED file(s) have unparseable frontmatter (no opening '---', or unclosed)" >&2

TOTAL_INDEXED=0
if [ -n "$ALL_RECS" ]; then
    TOTAL_INDEXED="$(printf '%s\n' "$ALL_RECS" | grep -c .)"
fi

if [ "$TOTAL_INDEXED" -eq 0 ]; then
    echo "build-record-index: zero records indexed from ${ROOTS[*]} -- aborting (a silently-empty index is the worst failure mode here)" >&2
    exit 1
fi

# abspath \t relpath \t id \t description, sorted by id (LC_ALL=C), abspath
# as a deterministic tiebreak so two runs on unchanged input are always
# byte-identical.
# ALL_RECS is built by plain string concatenation (not a command
# substitution), so it already carries its own trailing newline; grep -v
# '^$' drops the resulting one spurious blank line (and any that would come
# from an empty root contributing nothing) before it can become a phantom
# empty-name row in the breakdown below.
SORTED="$(printf '%s\n' "$ALL_RECS" | grep -v '^$' | LC_ALL=C sort -t "$(printf '\t')" -k3,3 -k1,1)"

# Cross-root id collision: a duplicate id anywhere in the merged set aborts
# (same-root duplicates are lint-frontmatter.sh's UNIQUE check to catch;
# this is specifically the case that check cannot see -- two different
# roots, or --root scans that overlap).
COLLISIONS=""
PREV_ID=""
PREV_PATH=""
while IFS="$(printf '\t')" read -r cabs _crel cid _cdesc; do
    [ -n "$cid" ] || continue
    if [ "$cid" = "$PREV_ID" ] && [ "$cabs" != "$PREV_PATH" ]; then
        COLLISIONS="${COLLISIONS}build-record-index: duplicate id '$cid': $PREV_PATH AND $cabs
"
    fi
    PREV_ID="$cid"
    PREV_PATH="$cabs"
done <<< "$SORTED"
if [ -n "$COLLISIONS" ]; then
    printf '%s' "$COLLISIONS" >&2
    echo "build-record-index: aborting -- duplicate ids across roots must be resolved (see above)" >&2
    exit 1
fi

INDEX_FILE="$OUT_DIR/index.txt"
MAP_FILE="$OUT_DIR/map.tsv"
: > "$INDEX_FILE"
: > "$MAP_FILE"

n=0
while IFS="$(printf '\t')" read -r path _relpath id desc; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    printf '%d :: %s\n' "$n" "$desc" >> "$INDEX_FILE"
    printf '%d\t%s\t%s\n' "$n" "$id" "$path" >> "$MAP_FILE"
done <<< "$SORTED"

BREAKDOWN_STR="$(
    printf '%s\n' "$SORTED" | awk -F'\t' '
        {
            n = split($2, parts, "/")
            store = (parts[1] == "plans") ? "plans" : parts[1] "/" parts[2]
            count[store]++
        }
        END {
            for (s in count) {
                name = s
                sub(/^.*\//, "", name)
                printf "%d\t%s\n", count[s], name
            }
        }
    ' | sort -k1,1rn -k2,2 | awk -F'\t' '{ printf "%s%s %d", (NR > 1 ? ", " : ""), $2, $1 }'
)"

echo "build-record-index: indexed $TOTAL_INDEXED record(s) from ${#ROOTS[@]} root(s) [${ROOTS[*]}] ($BREAKDOWN_STR)" >&2

SKIPPED=$((ID_NO_DESC + DESC_NO_ID + UNPARSED))
if [ "$STRICT" -eq 1 ] && [ "$SKIPPED" -gt 0 ]; then
    echo "build-record-index: --strict: $SKIPPED file(s) skipped (see counts above) -- failing" >&2
    exit 1
fi

exit 0
