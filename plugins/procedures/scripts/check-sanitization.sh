#!/usr/bin/env bash
# check-sanitization.sh — reject records that leak content unsafe to publish.
#
# Both store repos are treated "as if public", so leak-checking is a universal
# floor (see specs/RECORD_ADMISSIBILITY.md §Validate — baseline). Generalized
# from langwatch's clone-local check-sanitization.sh: the leak classes only, no
# store-specific string. This is the personal-path / token / private-key layer
# gitleaks misses, NOT a full secret scanner.
#
# Leak classes (any hit → exit 1, offending file:line to stdout):
#   - personal macOS home path   /Users/<name>/
#   - personal Linux home path   /home/<name>/   (except /home/ubuntu/, allowed)
#   - Slack token                xox[bapr]-
#   - private key material       -----BEGIN ... PRIVATE KEY-----
#
# Usage:
#   check-sanitization.sh <file> [file..]   # check exactly the named files
#   check-sanitization.sh                   # check every tracked file under CWD
#                                           # (git ls-files; find fallback)
#
# Pure grep; no network, no LLM. Runs for every store as a commit-records.sh
# baseline step, and standalone.

set -uo pipefail

prog="check-sanitization"

# Collect targets: explicit args, else every tracked file (or a find fallback
# outside a git tree).
if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        FILES=()
        while IFS= read -r _f; do FILES+=("$_f"); done < <(git ls-files)
    else
        FILES=()
        while IFS= read -r _f; do FILES+=("${_f#./}"); done \
            < <(find . -type f -not -path './.git/*')
    fi
fi

FAIL=0

# _scan <file> <grep-args...> — run grep once, PURE: prints matches on stdout,
# returns grep's own status. The caller distinguishes 0 (match), 1 (no match),
# and >1 (a scan error — unreadable file, bad encoding). A scan error must FAIL
# CLOSED at the call site: it may never read as "no match", or a file we could
# not scan would pass the gate.
_scan() {
    local file="$1"; shift
    grep "$@" "$file" 2>/dev/null
}

for f in ${FILES[@]+"${FILES[@]}"}; do
    case "$f" in
        */check-sanitization.sh | check-sanitization.sh) continue ;;
    esac
    # Fail closed: a named target that is missing or not a readable regular
    # file is an error, not a silent skip.
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        echo "$prog: FAIL: $f — missing or unreadable; failing closed"
        FAIL=1
        continue
    fi

    # Personal macOS home path — any /Users/<name>/ (no carve-out). Case-
    # insensitive, matched per occurrence so a mixed-content line cannot hide it.
    hits="$(_scan "$f" -nioE '/Users/[^/]+/')"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$prog: FAIL: $f — personal macOS home path:"
        printf '%s\n' "$hits" | head -1
        FAIL=1
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi

    # Personal Linux home path — every /home/<name>/ occurrence except exactly
    # /home/ubuntu/. Per occurrence (not per line), so /home/ubuntu/ok beside
    # /home/bob/x on one line still trips; a /home/ubuntu/../ traversal that
    # escapes the allowed segment also trips.
    hits="$(_scan "$f" -nioE '/home/[^/]+/')"; rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    elif [ "$rc" -eq 0 ]; then
        bad="$(printf '%s\n' "$hits" | grep -vE ":/home/ubuntu/$")"
        trav="$(_scan "$f" -nioE '/home/[^/]+/\.\.')"
        both="$(printf '%s\n%s\n' "$bad" "$trav" | grep -v '^$')"
        if [ -n "$both" ]; then
            echo "$prog: FAIL: $f — personal Linux home path:"
            printf '%s\n' "$both" | head -1
            FAIL=1
        fi
    fi

    # Slack token
    hits="$(_scan "$f" -nE 'xox[bapr]-')"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$prog: FAIL: $f — Slack token:"
        printf '%s\n' "$hits" | head -1
        FAIL=1
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi

    # Private key material
    _scan "$f" -n -- '-----BEGIN .*PRIVATE KEY-----' >/dev/null; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$prog: FAIL: $f — private key material"
        FAIL=1
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "$prog: FAILED"
    exit 1
fi
echo "$prog: OK"
