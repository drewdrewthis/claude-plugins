#!/usr/bin/env bash
# stores.sh — single source of truth for the seven codex record stores.
#
# Source this file from any script that needs the store list:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/stores.sh"   # from hooks/
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/stores.sh"                  # from scripts/
#
# Exports:
#   STORES           — bash array of the seven store paths (relative to repo root)
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
)

# Vendor stores (titw-managed, DECISIONS D23 in drewdrewthis/titw): queried by
# query-records.sh but NOT linted/backfilled — vendored records are validated
# by `titw check` at publish time, not by the consumer's lint. Kept out of
# STORES so every existing STORES consumer is untouched by vendored content.
VENDOR_STORES=(
    titw
)

# QUERY_RECORDS_EXTRA_STORES — optional, space-separated store paths (relative
# to the query root) appended to the scan list. Env-based on purpose: settings
# `env` maps stack by scope (user -> project -> local), so a project can add a
# store without a plugin release. Like vendor stores, extras are queried, never
# linted.
if [ -n "${QUERY_RECORDS_EXTRA_STORES:-}" ]; then
    # shellcheck disable=SC2206 -- word-splitting is the documented format
    VENDOR_STORES+=(${QUERY_RECORDS_EXTRA_STORES})
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
