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
for f in ${FILES[@]+"${FILES[@]}"}; do
    [ -f "$f" ] || continue
    case "$f" in
        */check-sanitization.sh | check-sanitization.sh) continue ;;
    esac

    if grep -nE '/Users/[a-z][a-z0-9._-]*/' "$f" >/dev/null 2>&1; then
        echo "$prog: FAIL: $f — personal macOS home path:"
        grep -nE '/Users/[a-z][a-z0-9._-]*/' "$f" | head -1
        FAIL=1
    fi

    if grep -nE '/home/[a-z][a-z0-9._-]*/' "$f" 2>/dev/null | grep -vE '/home/ubuntu/' >/dev/null 2>&1; then
        echo "$prog: FAIL: $f — personal Linux home path:"
        grep -nE '/home/[a-z][a-z0-9._-]*/' "$f" | grep -vE '/home/ubuntu/' | head -1
        FAIL=1
    fi

    if grep -nE 'xox[bapr]-' "$f" >/dev/null 2>&1; then
        echo "$prog: FAIL: $f — Slack token:"
        grep -nE 'xox[bapr]-' "$f" | head -1
        FAIL=1
    fi

    if grep -n -- '-----BEGIN .*PRIVATE KEY-----' "$f" >/dev/null 2>&1; then
        echo "$prog: FAIL: $f — private key material"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "$prog: FAILED"
    exit 1
fi
echo "$prog: OK"
