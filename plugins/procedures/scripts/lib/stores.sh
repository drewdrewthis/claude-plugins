#!/usr/bin/env bash
# stores.sh — single source of truth for the codex record stores.
#
# The store set is DISCOVERED, not hardcoded: every directory one level under
# RECORDS_ROOT becomes a store at source time, so a new store directory is
# picked up with zero edits here (previously ten+ existing directories —
# adrs, archive, language, mandates, policies, postmortems, proofs,
# proposals, scenarios, systemd-dropins, plus the nested references/plans —
# were silently never linted because nobody had added them to a fixed list).
# One store per GRC artifact class among the discovered directories: risk
# register (failure-modes), governance choices (decisions), control patterns
# (solutions), control implementations (procedures), evidence (research),
# roadmap (plans), judgment rules (principles), architecture decision
# records (adrs), absolute constraints (invariants), standing authority
# (policies), control objectives (standards) — plus whatever else lives
# under RECORDS_ROOT.
#
# Source this file from any script that needs the store list:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/stores.sh"   # from hooks/
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/stores.sh"                  # from scripts/
#
# Exports:
#   STORES           — bash array of store paths (relative to repo root),
#                      discovered by listing directories under RECORDS_ROOT,
#                      plus the fixed rule stores and top-level "plans" (see
#                      REQUIRED_STORES below). Assumes CWD is already the
#                      corpus root — callers `cd "$ROOT"` before sourcing
#                      this (see lint-frontmatter.sh / query-records.sh).
#   STORES_ALT       — pipe-separated alternation for grep -E / sed -E patterns
#                      e.g. "references/failure-modes|references/decisions|..."
#
# NOTE: hooks run as subprocesses; source via a path derived from the script's
# own ${BASH_SOURCE[0]}, NOT from $CLAUDE_PROJECT_DIR (not exported to hooks).

# Every directory found one level under RECORDS_ROOT becomes a store.
RECORDS_ROOT="references"

# Vendor stores (titw-managed, DECISIONS D23 in drewdrewthis/titw): queried by
# query-records.sh but NOT linted/backfilled — vendored records are validated
# by `titw check` at publish time, not by the consumer's lint. Excluded from
# discovery below by basename, so a vendor directory landing under
# RECORDS_ROOT is still never treated as a lintable store.
# shellcheck disable=SC2034  # consumed by sourcing scripts (query-records.sh)
VENDOR_STORES=(
    titw
)

# GRC rule stores: kept explicit, not directory-derived. These four must stay
# declared even before their directory exists on disk — invariant (absolute)
# vs principle (judgment) vs policy (standing authority) vs standard
# (measurable bar) is a fixed taxonomy, not a filesystem listing. Dropping
# one silently collapses that distinction back into "principle with a flag"
# (hooks/tests/store-list-drift.bats pins this).
REQUIRED_STORES=(
    references/invariants
    references/principles
    references/policies
    references/standards
)

# Append $1 to STORES if not already present. Bash-3.2-safe (no associative
# arrays). Both discovery and REQUIRED_STORES funnel through this so a store
# never lands in STORES twice — corpus_files() runs `find` per STORES entry,
# and a duplicate entry would make lint-frontmatter.sh scan (and therefore
# id-collect) that store's files twice, reporting every id in it as a false
# duplicate.
_stores_add() {
    local candidate="$1" existing
    for existing in ${STORES[@]+"${STORES[@]}"}; do
        [ "$existing" = "$candidate" ] && return 0
    done
    STORES+=("$candidate")
}

_stores_discover() {
    STORES=()
    local d base v skip

    for d in "${REQUIRED_STORES[@]}"; do
        _stores_add "$d"
    done

    # plans/ is the one record store outside RECORDS_ROOT.
    [ -d "plans" ] && _stores_add "plans"

    if [ -d "$RECORDS_ROOT" ]; then
        for d in "$RECORDS_ROOT"/*/; do
            [ -d "$d" ] || continue
            d="${d%/}"
            base="${d##*/}"
            skip=0
            for v in ${VENDOR_STORES[@]+"${VENDOR_STORES[@]}"}; do
                if [ "$base" = "$v" ]; then
                    skip=1
                    break
                fi
            done
            [ "$skip" -eq 1 ] && continue
            _stores_add "$d"
        done
    fi
}
_stores_discover

# QUERY_RECORDS_EXTRA_STORES — optional, space-separated, root-relative store
# paths that query-records.sh appends to its scan list. A SEPARATE array from
# VENDOR_STORES: extras are runtime config, so they are neither linted nor part
# of the drift-tested doc contract. Env-based on purpose: settings `env` maps
# stack by scope (user -> project -> local), so a project can add a store
# without a plugin release. Entries are literal relative paths — absolute
# paths, `..`, and glob characters are rejected (loudly, on stderr).
# shellcheck disable=SC2034  # consumed by sourcing scripts (query-records.sh)
EXTRA_STORES=()
if [ -n "${QUERY_RECORDS_EXTRA_STORES:-}" ]; then
    set -f
    for _e in ${QUERY_RECORDS_EXTRA_STORES}; do
        case "$_e" in
            /* | *..* | *[\*\?\[]* )
                echo "stores.sh: ignoring invalid QUERY_RECORDS_EXTRA_STORES entry: $_e" >&2 ;;
            * )
                EXTRA_STORES+=("$_e") ;;
        esac
    done
    set +f
    unset _e
fi

# Build pipe-alternation of full store paths for grep -E / sed -E patterns.
STORES_ALT=""
for _s in "${STORES[@]}"; do
    STORES_ALT="${STORES_ALT:+${STORES_ALT}|}${_s}"
done

# Build pipe-alternation of store BASENAMES for links sub-key stripping.
# e.g. "failure-modes|decisions|solutions|procedures|research|plans|principles"
STORES_BASENAME_ALT=""
for _s in "${STORES[@]}"; do
    _b="${_s##*/}"
    STORES_BASENAME_ALT="${STORES_BASENAME_ALT:+${STORES_BASENAME_ALT}|}${_b}"
done
unset _s _b
