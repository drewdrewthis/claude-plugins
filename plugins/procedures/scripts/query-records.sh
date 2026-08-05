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
# Flags (combine with AND logic — every condition must hold):
#   --keyword <tok>   records whose frontmatter `keywords` contain the token
#                     (same tokenization + shared matcher as the router).
#   --kind <kind>     records whose frontmatter `kind:` equals <kind>.
#   --id <id>         the record whose frontmatter `id:` equals <id> exactly.
#   --links-to <id>   records whose `links:` value references <id>.
#
# Output: `path — gloss` lines (same shape as the router). Capped at 20.
# No match: empty stdout, exit 0.
#
# Pure bash/grep/awk; no network, no LLM.
#
# Usage:
#   scripts/query-records.sh --keyword autonomy
#   scripts/query-records.sh --kind procedure
#   scripts/query-records.sh --id dec.2026-06-12-skill-is-invokable-procedure
#   scripts/query-records.sh --links-to fm.unverified-claim-acted-on
#   scripts/query-records.sh --kind solution --keyword autonomy   # AND

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

LIMIT=20

# ---- parse flags ----
Q_KEYWORD=""
Q_KIND=""
Q_ID=""
Q_LINKS_TO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keyword)  Q_KEYWORD="${2:-}"; shift 2 ;;
        --kind)     Q_KIND="${2:-}"; shift 2 ;;
        --id)       Q_ID="${2:-}"; shift 2 ;;
        --links-to) Q_LINKS_TO="${2:-}"; shift 2 ;;
        *) echo "query-records: unknown flag: $1" >&2; exit 2 ;;
    esac
done

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

# Extract the frontmatter `<key>:` raw RHS value from a file.
fm_value() {
    # $1 = file, $2 = key. Reads only the frontmatter block (between fences).
    awk -v k="$2" '
        NR==1 && $0!="---" { exit }
        NR==1 { next }
        /^---$/ { exit }
        $0 ~ "^"k":" { sub("^"k":[[:space:]]*",""); print; exit }
    ' "$1"
}

# Gloss extraction reused for the structural-filter output path. Same shape as
# the matcher: first body heading, else first non-empty body line.
gloss_of() {
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm==1 && $0=="---" { infm=0; next }
        infm==1 { next }
        glossset==1 { next }
        /^#+[[:space:]]/ { g=$0; sub(/^#+[[:space:]]*/,"",g); print g; glossset=1; exit }
        /[^[:space:]]/ { print; glossset=1; exit }
    ' "$1" | awk '{ gsub(/[[:space:]]+/," "); sub(/^ /,""); sub(/ $/,"");
                    if (length($0)>90) $0=substr($0,1,87) "...";
                    if ($0=="") $0="(record)"; print }'
}

# ---- apply the structural filters (kind / id / links-to) to narrow files ----
# Each filter intersects the candidate set. --keyword is applied last via the
# shared matcher (it needs the rarity pre-pass over the narrowed set).
filter_structural() {
    # reads file paths on stdin, prints the ones passing kind/id/links-to.
    local f val
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -n "$Q_KIND" ]; then
            val="$(fm_value "$f" kind)"
            val="${val%%[[:space:]]*}"
            [ "$val" = "$Q_KIND" ] || continue
        fi
        if [ -n "$Q_ID" ]; then
            val="$(fm_value "$f" id)"
            val="${val%%[[:space:]]*}"
            [ "$val" = "$Q_ID" ] || continue
        fi
        if [ -n "$Q_LINKS_TO" ]; then
            val="$(fm_value "$f" links)"
            # strip braces/brackets and the sub-key names, split on separators,
            # then look for an exact id token match.
            local ids
            ids="$(printf '%s' "$val" \
                | tr -d '{}[]' \
                | sed -E "s/(${STORES_BASENAME_ALT}):/ /g" \
                | tr ',' ' ')"
            local found=0 lid
            for lid in $ids; do
                lid="${lid//\"/}"; lid="${lid//\'/}"
                [ -n "$lid" ] || continue
                if [ "$lid" = "$Q_LINKS_TO" ]; then found=1; break; fi
            done
            [ "$found" -eq 1 ] || continue
        fi
        printf '%s\n' "$f"
    done
}

NARROWED="$(printf '%s\n' "$ALL_FILES" | filter_structural)"
[ -z "$NARROWED" ] && exit 0

# ---- keyword path: hand the narrowed set to the SHARED matcher ----
if [ -n "$Q_KEYWORD" ]; then
    # tokenize the keyword the same way the router tokenizes its prompt.
    TOKEN_FILE="$(mktemp)"
    IDF_FILE="$(mktemp)"
    trap 'rm -f "$TOKEN_FILE" "$IDF_FILE"' EXIT
    printf '%s' "$Q_KEYWORD" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '\n' \
        | awk 'length($0) >= 3' \
        | sort -u > "$TOKEN_FILE"
    if [ ! -s "$TOKEN_FILE" ]; then
        # keyword tokenized to nothing (e.g. all <3 chars) — no matches.
        exit 0
    fi
    # IDF pre-pass over the narrowed set, shared lib (df + idf + corpus stats).
    printf '%s\n' "$NARROWED" | awk -f "$LIB_DIR/record-rarity.awk" > "$IDF_FILE"
    # The PULL path is deliberately permissive: an explicit single-token query
    # (e.g. --keyword issue) must still surface that token's records even though
    # the PUSH gate would suppress a lone common token. So pass gate=0 to turn
    # OFF the absolute df<=K_floor floor — the matcher then ranks every record
    # with >=1 matched token and returns the top-N. The router keeps gate=1.
    printf '%s\n' "$NARROWED" | awk \
        -v tokfile="$TOKEN_FILE" \
        -v idffile="$IDF_FILE" \
        -v gate=0 \
        -v limit="$LIMIT" \
        -f "$LIB_DIR/record-match.awk"
    exit 0
fi

# ---- no keyword: emit the structurally-narrowed records as path — gloss ----
n=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$n" -ge "$LIMIT" ] && break
    printf '%s — %s\n' "$f" "$(gloss_of "$f")"
    n=$((n + 1))
done <<< "$NARROWED"

exit 0
