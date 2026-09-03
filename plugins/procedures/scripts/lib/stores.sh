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

# _stores_resolve_roots_spec — single source of truth for the
# CODEX_STORE_ROOTS spec string, used by stores.sh's own default below,
# build-record-index.sh, and how-do-i.sh's roots.stamp (so the stamp can
# never drift from what a rebuild actually scans).
#
# Precedence: $CODEX_STORE_ROOTS (real env) > settings.json
# (.env.CODEX_STORE_ROOTS) > ~/.knowledge/config.json `modules` (array of
# module names and/or absolute paths; reads $KNOWLEDGE_HOME/config.json when
# that env is set, else $HOME/.knowledge/config.json) > auto-discovered
# ${KNOWLEDGE_HOME:-$HOME/.knowledge}/modules/*/ git repos (sorted) > $CODEX_ROOT
# (legacy explicit single-root override) > hardcoded
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
# The two ~/.knowledge tiers sit BELOW settings.json/env (an explicit
# CODEX_STORE_ROOTS still wins) but ABOVE the legacy CODEX_ROOT single-root:
# the knowledge home is the modern multi-repo layout and, once present, should
# outrank a legacy single-root guess. config.json `modules`, when a non-empty
# array, REPLACES auto-discovery — it is the explicit ordered manifest; a bare
# name resolves under $KNOWLEDGE_HOME/modules/<name>, an absolute path is used
# as-is. Both ~/.knowledge tiers require jq and fail open (missing file, no
# `modules` key, invalid JSON, no jq) to the next tier down.
# The settings.json step ranks before CODEX_ROOT because a long-lived session
# (or an out-of-session shell) started before CODEX_STORE_ROOTS was added to
# settings.json's `env` block never has the var in its process env — without
# this fallback such a session silently scans the wrong root and, since
# roots.stamp still records the (unchanged) wrong value, never self-repairs.
# settings.json is the source of truth for multi-root configs and should
# always outrank the legacy CODEX_ROOT single-root override.
#
# Set CODEX_STORE_ROOTS_DEBUG=1 to log the winning source to stderr.
_stores_resolve_roots_spec() {
    if [ -n "${CODEX_STORE_ROOTS:-}" ]; then
        [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from \$CODEX_STORE_ROOTS env" >&2
        printf '%s' "$CODEX_STORE_ROOTS"
        return
    fi
    local settings_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    if [ -f "$settings_file" ] && command -v jq >/dev/null 2>&1; then
        local from_settings
        from_settings="$(jq -r '.env.CODEX_STORE_ROOTS // empty' "$settings_file" 2>/dev/null || true)"
        if [ -n "$from_settings" ]; then
            [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from settings.json ($settings_file)" >&2
            printf '%s' "$from_settings"
            return
        fi
    fi

    # NEW: ~/.knowledge/config.json `modules` — an explicit ordered manifest of
    # store roots. Each entry is either an absolute path (used verbatim) or a
    # bare module name (resolved under $KNOWLEDGE_HOME_DEFAULT/modules/<name>).
    # When present and non-empty this REPLACES the auto-discovery tier below —
    # the manifest is authoritative. Reads .modules straight to one-value-per-
    # line via jq (array-typed only; a non-array or absent key yields nothing).
    # jq-guarded and fail-open: a missing file, no key, invalid JSON, or no jq
    # all leave $spec empty and fall through to the next tier.
    local khome_default cfg spec
    khome_default="${KNOWLEDGE_HOME:-$HOME/.knowledge}"
    cfg="$khome_default/config.json"
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        local _modules_raw _m
        _modules_raw="$(jq -r '.modules // empty | if type=="array" then .[] else empty end' "$cfg" 2>/dev/null || true)"
        spec=""
        while IFS= read -r _m; do
            [ -n "$_m" ] || continue
            case "$_m" in
                /*) spec="${spec:+$spec:}$_m" ;;
                *)  spec="${spec:+$spec:}$khome_default/modules/$_m" ;;
            esac
        done <<< "$_modules_raw"
        if [ -n "$spec" ]; then
            [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from ~/.knowledge/config.json modules" >&2
            printf '%s' "$spec"
            return
        fi
    fi

    # NEW: auto-discover — every immediate subdir of
    # $KNOWLEDGE_HOME_DEFAULT/modules/ that carries a `.git` entry (dir OR file:
    # worktrees use a `.git` file, hence -e not -d) becomes a root. The glob
    # `modules/*/` is already lexically sorted by bash, so roots come out in
    # alphabetical order with no explicit sort. Only used when at least one such
    # subdir is found; otherwise fall through to the legacy tiers.
    if [ -d "$khome_default/modules" ]; then
        spec=""
        local _d
        for _d in "$khome_default"/modules/*/; do
            [ -d "$_d" ] || continue
            _d="${_d%/}"
            [ -e "$_d/.git" ] || continue
            spec="${spec:+$spec:}$_d"
        done
        if [ -n "$spec" ]; then
            [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from ~/.knowledge/modules/ auto-discovery" >&2
            printf '%s' "$spec"
            return
        fi
    fi

    if [ -n "${CODEX_ROOT:-}" ]; then
        [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from \$CODEX_ROOT env (legacy)" >&2
        printf '%s' "$CODEX_ROOT"
        return
    fi
    [ -n "${CODEX_STORE_ROOTS_DEBUG:-}" ] && echo "stores.sh: roots from hardcoded default" >&2
    printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

_stores_split_roots "$(_stores_resolve_roots_spec)"

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

# _stores_knowledge_config_get <key> — prints the raw jq value at .<key> in
# $KNOWLEDGE_HOME/config.json (default $HOME/.knowledge/config.json), or
# nothing if the file/key is absent, invalid JSON, or jq is unavailable.
# Caller checks for empty output. No filesystem writes, fail-open on every
# missing piece — config.json is optional by design. (The roots resolver reads
# .modules inline rather than through this helper, since it wants array
# elements one-per-line, not a single value.)
_stores_knowledge_config_get() {
    local key="$1" khome cfg
    khome="${KNOWLEDGE_HOME:-$HOME/.knowledge}"
    cfg="$khome/config.json"
    [ -f "$cfg" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r ".${key} // empty" "$cfg" 2>/dev/null || true
}

# procedures_state_dir — per-machine LIBRARIAN RUNTIME STATE directory, prints
# the path (no filesystem access beyond an optional config.json read, no CWD
# dependency, safe at any time).
#
# This is deliberately NOT a store. Everything above lives under a git-tracked
# corpus root and is scanned by lint-frontmatter/build-record-index; this is
# local, per-machine runtime state — the librarian's read cursors, its
# grooming queue, its single-writer lock — that must NEVER be committed. It
# previously sat inside ~/.claude (itself a tracked repo), where a `git add -A`
# staged thousands of per-machine churn files (~2900 cursor files on one box).
# So it moves out of the corpus entirely, onto the XDG state-dir convention
# (state, not config/cache: mutable data that outlives a process but is not
# user-configured and is safe to lose).
#
# Precedence is now ~/.knowledge-aware (four tiers, highest first):
#   1. $PROCEDURES_STATE_DIR — explicit override (e.g. tests), always wins.
#   2. ~/.knowledge/config.json key `state_dir` — a plain absolute-path string
#      (jq-guarded; a missing file / key / jq falls through).
#   3. ${KNOWLEDGE_HOME:-$HOME/.knowledge}/state — but ONLY if that ~/.knowledge
#      directory itself EXISTS on disk. Merely having KNOWLEDGE_HOME set is not
#      enough: a box that never opted into the knowledge home must not have its
#      librarian state silently relocated under a directory that isn't there.
#   4. hardcoded ${XDG_STATE_HOME:-$HOME/.local/state}/procedures/librarian —
#      the XDG state-dir fallback, unchanged, for every box without ~/.knowledge.
# So this no longer merely mirrors the $CLAUDE_CONFIG_DIR pattern above — it
# also reads config.json and probes for the knowledge home's existence.
#
# Exported (export -f) so a caller can `source stores.sh` and invoke it.
procedures_state_dir() {
    if [ -n "${PROCEDURES_STATE_DIR:-}" ]; then
        printf '%s' "$PROCEDURES_STATE_DIR"
        return
    fi
    local from_config khome
    from_config="$(_stores_knowledge_config_get state_dir)"
    if [ -n "$from_config" ]; then
        printf '%s' "$from_config"
        return
    fi
    khome="${KNOWLEDGE_HOME:-$HOME/.knowledge}"
    if [ -d "$khome" ]; then
        printf '%s' "$khome/state"
        return
    fi
    printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/procedures/librarian"
}
export -f procedures_state_dir 2>/dev/null || true
