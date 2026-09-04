#!/usr/bin/env bash
# require-bash4.sh — guarantee the script runs under bash 4+.
#
# WHY THIS EXISTS
#   compile-records.sh and lint-frontmatter.sh use associative arrays
#   (`declare -A`), which require bash 4. On macOS the system bash frozen at
#   3.2.57 (a GPLv3 licensing freeze) is what `/bin/bash` — AND plain `bash` on
#   PATH in a non-interactive/non-login shell (e.g. Claude Code's own Bash tool)
#   — resolves to. Homebrew's bash 5 at /opt/homebrew/bin/bash only wins in an
#   interactive login shell where the user's PATH customizations apply. A caller
#   that runs `bash <script>` therefore feeds these scripts a 3.2 interpreter
#   and `declare -A` dies with `invalid option`, crashing the whole pipeline
#   (how-do-i.sh shells out to compile-records.sh via `bash "$COMPILE_SCRIPT"`).
#
#   So: source this early and call `require_bash4 "$0" "$@"` BEFORE any
#   `declare -A` executes. If we are already on bash 4+, it is a no-op. If not,
#   it re-execs the script under the first bash 4+ interpreter it can find, or
#   dies with a clear install hint.
#
# USAGE (from a scripts/ script, right after SCRIPT_DIR is resolved):
#   source "$SCRIPT_DIR/lib/require-bash4.sh"
#   require_bash4 "$0" "$@"
#
# TEST SEAMS (all unset in production; documented so the search logic is
# exercisable without an actual bash<4 host or the real filesystem):
#   REQUIRE_BASH4_CANDIDATE_PATHS  colon-separated absolute bash paths to probe
#                                  in place of the default Homebrew locations.
#                                  Set-but-empty disables the fixed-path branch
#                                  (used only when UNSET does it default).
#   REQUIRE_BASH4_PATH_PREPEND     colon-separated dirs prepended to PATH for
#                                  the final `command -v bash` lookup.
#                                  Set-but-empty prepends nothing (unset ->
#                                  default Homebrew dirs).
#   _REQUIRE_BASH4_FORCE_MAJOR     override the detected running-bash major
#                                  version (to simulate bash<4 under a bash5
#                                  test runner).
# These pick the same defaults production uses when unset, so the finder's
# fixed-path branches are driven through `command -v` against a controlled PATH
# rather than literal `[ -x /opt/homebrew/bin/bash ]` checks — keeping the
# production logic simple AND fully mockable.

# _require_bash4_version_ok <candidate> — true iff <candidate> names an
# invocable bash whose major version is >= 4. Checks existence with
# `command -v` first, then actually invokes it to read its own BASH_VERSINFO —
# a candidate that exists but is broken/aliased/reports <4 is rejected.
# Bash-3.2-safe: no bash4-only syntax here.
_require_bash4_version_ok() {
    local candidate="$1" major
    [ -n "$candidate" ] || return 1
    command -v "$candidate" >/dev/null 2>&1 || return 1
    # Single quotes are deliberate: BASH_VERSINFO must be expanded by the
    # CANDIDATE we invoke, not by the current shell.
    # shellcheck disable=SC2016
    major="$("$candidate" -c 'printf %s "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)" || return 1
    case "$major" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$major" -ge 4 ]
}

# _require_bash4_find_interpreter — pure search. Prints the path of the first
# bash 4+ interpreter found (and returns 0), or prints nothing and returns 1.
# No exec, no exit — safe to call directly from a test, and safe to run even
# under bash 3.2 (uses no bash4-only syntax).
#
# Search order (spec):
#   a. $BASH env var
#   b/c. fixed absolute paths (REQUIRE_BASH4_CANDIDATE_PATHS, default the two
#        canonical Homebrew bash locations)
#   d. "$(brew --prefix bash)/bin/bash", only if brew is on PATH and succeeds
#   e. a `bash5`-named binary on PATH
#   f. `bash` resolved against PATH with the Homebrew dirs prepended, in case a
#      newer bash sits at a fixed location the caller's own PATH would not reach
_require_bash4_find_interpreter() {
    local candidate old_ifs brew_prefix

    # (a) $BASH
    if [ -n "${BASH:-}" ] && _require_bash4_version_ok "${BASH}"; then
        printf '%s\n' "${BASH}"
        return 0
    fi

    # (b)+(c) fixed absolute paths (overridable for test injection).
    old_ifs="$IFS"
    IFS=':'
    # shellcheck disable=SC2086  # deliberate word-split of the colon list
    set -- ${REQUIRE_BASH4_CANDIDATE_PATHS-/opt/homebrew/bin/bash:/usr/local/bin/bash}
    IFS="$old_ifs"
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        if _require_bash4_version_ok "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    # (d) brew --prefix bash
    if command -v brew >/dev/null 2>&1; then
        if brew_prefix="$(brew --prefix bash 2>/dev/null)" && [ -n "$brew_prefix" ]; then
            candidate="$brew_prefix/bin/bash"
            if _require_bash4_version_ok "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    fi

    # (e) a bash5-named binary
    if candidate="$(command -v bash5 2>/dev/null)" && [ -n "$candidate" ]; then
        if _require_bash4_version_ok "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    # (f) bash on a PATH with the Homebrew dirs prepended
    if candidate="$(PATH="${REQUIRE_BASH4_PATH_PREPEND-/opt/homebrew/bin:/usr/local/bin}${PATH:+:$PATH}" command -v bash 2>/dev/null)" \
        && [ -n "$candidate" ]; then
        if _require_bash4_version_ok "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    return 1
}

# _require_bash4_die <prog-path> — print the requirement error and exit 1.
_require_bash4_die() {
    local prog
    prog="$(basename "${1:-bash}" 2>/dev/null)" || prog="bash"
    printf "%s: requires bash 4 or newer (found bash %s); install one via 'brew install bash'\n" \
        "$prog" "${_REQUIRE_BASH4_FORCE_MAJOR:-${BASH_VERSINFO[0]:-?}}" >&2
    exit 1
}

# require_bash4 <prog-path> [args...] — no-op on bash 4+; otherwise re-exec the
# script under a found bash 4+ interpreter, or die. Call as:
#   require_bash4 "$0" "$@"
require_bash4() {
    local cur found
    cur="${_REQUIRE_BASH4_FORCE_MAJOR:-${BASH_VERSINFO[0]:-0}}"
    if [ "$cur" -ge 4 ] 2>/dev/null; then
        return 0
    fi

    # Re-exec loop guard: if we already re-exec'd once and STILL landed on
    # bash<4, do not exec again — a found interpreter that lied about its
    # version must not spin. Fall through to the error path instead.
    if [ -n "${_REQUIRE_BASH4_REEXEC:-}" ]; then
        _require_bash4_die "$@"
    fi

    if found="$(_require_bash4_find_interpreter)" && [ -n "$found" ]; then
        export _REQUIRE_BASH4_REEXEC=1
        exec "$found" "$@"
    fi

    _require_bash4_die "$@"
}
