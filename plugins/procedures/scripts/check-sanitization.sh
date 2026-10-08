#!/usr/bin/env bash
# check-sanitization.sh — reject records that leak content unsafe to publish.
#
# Both store repos are treated "as if public", so leak-checking is a universal
# floor (see specs/RECORD_ADMISSIBILITY.md §Validate — baseline). Generalized
# from langwatch's clone-local check-sanitization.sh: the leak classes only, no
# store-specific string. This is the personal-path / token / private-key layer
# gitleaks misses, NOT a full secret scanner.
#
# Leak classes (any hit → exit 1; the file, class and line number go to stdout,
# never the matched text, so the report itself cannot leak):
#   - personal macOS home path   /Users/<name>/
#   - personal Linux home path   /home/<name>/   (except /home/ubuntu/, allowed)
#   - Slack token                xox[bapr]-
#   - private key material       -----BEGIN ... PRIVATE KEY-----
#
# --strict (commit-records.sh uses it for mistakes.jsonl rows only, so record
# .md behaviour is unchanged) adds, after undoing JSON's \/ and \\ escapes:
#   - /Users/<name> and /home/<name> with no trailing slash (bare /home/ubuntu
#     stays allowed), C:\Users\<name>
#   - GitHub (gh[pousr]_, github_pat_), sk-ant- / sk- API keys, AWS AKIA keys,
#     Bearer tokens, and KEY|TOKEN|SECRET|PASSWORD = <12+ chars> assignments
# Free-text rows carry transcript prose, which leaks in more shapes than a
# hand-written record does.
#
# Usage:
#   check-sanitization.sh [--strict] <file> [file..]   # check the named files
#   check-sanitization.sh                   # check every tracked file under CWD
#                                           # (git ls-files; find fallback)
#
# Pure grep; no network, no LLM. Runs for every store as a commit-records.sh
# baseline step, and standalone.

set -uo pipefail

prog="check-sanitization"
STRICT=""
[ "${1:-}" = "--strict" ] && { STRICT=1; shift; }

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

# _report <class> <grep -n hits> — one FAIL line naming the class and the first
# hit's line number only: the matched text is the leak, so it is never echoed.
_report() {
    echo "$prog: FAIL: $f — $1 (line $(printf '%s\n' "$2" | head -1 | cut -d: -f1))"
    FAIL=1
}

# _class <class> <grep-args...> — scan $scan for one leak class; a scan error
# fails closed like a hit.
_class() {
    local label="$1" hits rc; shift
    hits="$(_scan "$scan" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        _report "$label" "$hits"
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi
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

    scan="$f"
    if [ -n "$STRICT" ]; then
        scan="$(mktemp)" && sed -e 's#\\/#/#g' -e 's#\\\\#\\#g' "$f" > "$scan" || {
            echo "$prog: FAIL: $f — could not unescape for scanning; failing closed"
            FAIL=1; continue
        }
    fi

    # Personal macOS home path — any /Users/<name>/ (no carve-out). Case-
    # insensitive, matched per occurrence so a mixed-content line cannot hide it.
    # --strict drops the trailing-slash requirement.
    if [ -n "$STRICT" ]; then mac='/Users/[^/[:space:]"\\]+'; else mac='/Users/[^/]+/'; fi
    _class "personal macOS home path" -nioE "$mac"

    # Personal Linux home path — every /home/<name>/ occurrence except exactly
    # /home/ubuntu/ (bare /home/ubuntu under --strict). Per occurrence (not per
    # line), so /home/ubuntu/ok beside /home/bob/x on one line still trips; a
    # /home/ubuntu/../ traversal that escapes the allowed segment also trips.
    if [ -n "$STRICT" ]; then
        lin='/home/[^/[:space:]"\\]+' ok=':/home/ubuntu$'
    else
        lin='/home/[^/]+/' ok=':/home/ubuntu/$'
    fi
    hits="$(_scan "$scan" -nioE "$lin")"; rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    elif [ "$rc" -eq 0 ]; then
        bad="$(printf '%s\n' "$hits" | grep -vE "$ok")"
        trav="$(_scan "$scan" -nioE '/home/[^/]+/\.\.')"
        both="$(printf '%s\n%s\n' "$bad" "$trav" | grep -v '^$')"
        [ -n "$both" ] && _report "personal Linux home path" "$both"
    fi

    _class "Slack token" -nE 'xox[bapr]-'
    _class "private key material" -n -- '-----BEGIN .*PRIVATE KEY-----'

    if [ -n "$STRICT" ]; then
        _class "personal Windows home path" -nioE '[a-z]:\\Users\\[^\\[:space:]"]+'
        _class "GitHub token" -nE '(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
        _class "API key" -nE '(^|[^A-Za-z0-9_-])(sk-ant-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,})'
        _class "AWS key" -nE '(^|[^A-Z0-9])AKIA[0-9A-Z]{16}'
        _class "bearer token" -nE 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
        _class "credential assignment" \
            -niE '(KEY|TOKEN|SECRET|PASSWORD)[[:space:]]*[=:][[:space:]]*[^[:space:]]{12,}'
        rm -f "$scan"
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "$prog: FAILED"
    exit 1
fi
echo "$prog: OK"
