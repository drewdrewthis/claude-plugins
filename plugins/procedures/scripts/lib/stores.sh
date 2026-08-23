#!/usr/bin/env bash
# stores.sh — single source of truth for the eleven codex record stores.
#
# The store set is one store per GRC artifact class: risk register
# (failure-modes), governance choices (decisions), control patterns (solutions),
# control implementations (procedures), evidence (research), roadmap (plans),
# judgment rules (principles), architecture decision records (adrs), absolute
# constraints (invariants), standing authority (policies), and control
# objectives (standards).
#
# Source this file from any script that needs the store list:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/stores.sh"   # from hooks/
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/stores.sh"                  # from scripts/
#
# Exports:
#   STORES           — bash array of the eleven store paths (relative to repo root)
#   STORES_ALT       — pipe-separated alternation for grep -E / sed -E patterns
#                      e.g. "references/failure-modes|references/decisions|..."
#
# NOTE: hooks run as subprocesses; source via a path derived from the script's
# own ${BASH_SOURCE[0]}, NOT from $CLAUDE_PROJECT_DIR (not exported to hooks).

STORES=(
    references/failure-modes
    references/decisions
    references/solutions
    references/procedures
    references/research
    plans
    references/principles
    references/adrs
    references/invariants
    references/policies
    references/standards
)

# Vendor stores (titw-managed, DECISIONS D23 in drewdrewthis/titw): queried by
# query-records.sh but NOT linted/backfilled — vendored records are validated
# by `titw check` at publish time, not by the consumer's lint. Kept out of
# STORES so every existing STORES consumer is untouched by vendored content.
# shellcheck disable=SC2034  # consumed by sourcing scripts (query-records.sh)
VENDOR_STORES=(
    titw
)

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
