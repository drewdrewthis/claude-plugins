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
#                      this (see lint-frontmatter.sh / build-record-index.sh).
#                      CWD-dependent and single-root: a multi-root caller
#                      loops STORE_ROOTS (below), `cd`s into each, and calls
#                      _stores_discover again per iteration to repopulate
#                      STORES for that root (build-record-index.sh does this).
#   STORES_ALT       — pipe-separated alternation for grep -E / sed -E patterns
#                      e.g. "references/failure-modes|references/decisions|..."
#   STORE_ROOTS      — bash array of absolute store-root directories (see
#                      CODEX_STORE_ROOTS below). Pure string parsing, CWD-
#                      independent, safe to use before any `cd`.
#
# NOTE: hooks run as subprocesses; source via a path derived from the script's
# own ${BASH_SOURCE[0]}, NOT from $CLAUDE_PROJECT_DIR (not exported to hooks).

# Every directory found one level under RECORDS_ROOT becomes a store.
RECORDS_ROOT="references"

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
    local d

    for d in "${REQUIRED_STORES[@]}"; do
        _stores_add "$d"
    done

    # plans/ is the one record store outside RECORDS_ROOT.
    [ -d "plans" ] && _stores_add "plans"

    if [ -d "$RECORDS_ROOT" ]; then
        for d in "$RECORDS_ROOT"/*/; do
            [ -d "$d" ] || continue
            d="${d%/}"
            _stores_add "$d"
        done
    fi
}
_stores_discover

# CODEX_STORE_ROOTS — colon-separated absolute roots to scan for stores,
# supporting more than one knowledge-store repo (e.g. a personal codex plus a
# team/vendor root). Default: this process's own ${CODEX_ROOT:-$HOME/.claude}
# — the same default build-record-index.sh already used as a single root, so
# a caller that never opts in sees an unchanged single-root STORE_ROOTS.
#
# Pure string parsing, no filesystem access, no CWD dependency — safe to
# compute at source time regardless of what CWD happens to be. A caller that
# has its OWN root override (a --root flag, a *_ROOT test env var, e.g.
# lint-frontmatter.sh's LINT_FRONTMATTER_ROOT) should call
# _stores_split_roots again with its own resolved default so that override
# still wins over the generic one computed here.
#
# Discovery itself stays per-root and CWD-relative (_stores_discover, above,
# unchanged): iterating STORE_ROOTS and re-running _stores_discover per root
# is the caller's job (build-record-index.sh, lint-frontmatter.sh).
_stores_split_roots() {
    STORE_ROOTS=()
    local spec="${1:-}" _raw=() _r
    IFS=':' read -r -a _raw <<< "$spec"
    for _r in ${_raw[@]+"${_raw[@]}"}; do
        [ -n "$_r" ] && STORE_ROOTS+=("$_r")
    done
}
_stores_split_roots "${CODEX_STORE_ROOTS:-${CODEX_ROOT:-$HOME/.claude}}"

# QUERY_RECORDS_EXTRA_STORES — optional, space-separated, root-relative store
# paths a survey tool may append to its scan list. Subsumed for the
# cross-repo case by CODEX_STORE_ROOTS above (add a whole extra root instead
# of one store within the current root) but kept as-is for the narrower
# same-root, runtime-config case it already serves. A SEPARATE array from
# STORE_ROOTS: extras are runtime config, so they are neither linted nor part
# of the drift-tested doc contract. Env-based on purpose: settings `env` maps
# stack by scope (user -> project -> local), so a project can add a store
# without a plugin release. Entries are literal relative paths — absolute
# paths, `..`, and glob characters are rejected (loudly, on stderr).
# shellcheck disable=SC2034  # consumed by sourcing scripts (build-record-index.sh)
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
