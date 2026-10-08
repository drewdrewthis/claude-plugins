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
#     Bearer tokens, and KEY|TOKEN|SECRET|PASSWORD = <value> assignments whose
#     value is 16+ chars mixing letters and digits
# Free-text rows carry transcript prose, which leaks in more shapes than a
# hand-written record does. Prose also NAMES these shapes, so --strict skips a
# hit whose WHOLE value is a placeholder: a home dir named <...>, user,
# username, name, me, you or someone (trailing .,;:) ignored); a credential
# value that is <...>, $VAR / ${VAR}, or contains "example". Token classes
# skip nothing.
#
# Usage:
#   check-sanitization.sh [--strict] <file|-> [file..]  # check the named files;
#                                           # `-` reads stdin (no temp file)
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
STDIN_TEXT=""
# A home-dir name as --strict matches it: stops at punctuation so `/Users/me,`
# reads as `me`, but keeps the <>${} that mark a placeholder.
NAME='[A-Za-z0-9._<>${}~-]+'

# _scan <file> <grep-args...> — run grep once, PURE: prints matches on stdout,
# returns grep's own status. The caller distinguishes 0 (match), 1 (no match),
# and >1 (a scan error — unreadable file, bad encoding). A scan error must FAIL
# CLOSED at the call site: it may never read as "no match", or a file we could
# not scan would pass the gate.
# --strict scans with JSON's \/ and \\ escapes undone, so an escaped path
# cannot slip past the path classes.
_scan() {
    local file="$1"; shift
    if [ "$file" != "-" ] && [ -z "$STRICT" ]; then
        grep "$@" "$file" 2>/dev/null
        return
    fi
    if [ "$file" = "-" ]; then printf '%s' "$STDIN_TEXT"; else cat -- "$file"; fi \
        | if [ -n "$STRICT" ]; then sed -e 's#\\/#/#g' -e 's#\\\\#\\#g'; else cat; fi \
        | grep "$@" 2>/dev/null
}

# _home_trim — `grep -no` home-path hits without trailing sentence punctuation.
_home_trim() { sed -E 's/[.,;:)]+$//'; }

# _home_real — trimmed home-path hits minus those whose name segment is wholly
# a placeholder or an allow name.
_home_real() {
    _home_trim | grep -viE '[/\\](user|username|name|me|you|someone|<[^>]*>)$'
}

# _cred_real — credential hits whose value (cut at the first \ " , or space)
# is 16+ chars mixing letters and digits and is not wholly a placeholder, so
# `key: some_column_name_here` and `TOKEN=${GITHUB_TOKEN}` are not secrets.
_cred_real() {
    awk '{ v = $0; sub(/^[0-9]+:[^=:]*[=:][ \t]*/, "", v); sub(/^[\\"\047]+/, "", v)
           sub(/[\\", \t].*$/, "", v)
           if (v ~ /^<[^>]*>$/ || v ~ /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/ || tolower(v) ~ /example/) next
           if (length(v) >= 16 && v ~ /[A-Za-z]/ && v ~ /[0-9]/) print }'
}

# _report <class> <grep -n hits> — one FAIL line naming the class and the first
# hit's line number only: the matched text is the leak, so it is never echoed.
_report() {
    echo "$prog: FAIL: $f — $1 (line $(printf '%s\n' "$2" | head -1 | cut -d: -f1))"
    FAIL=1
}

# _class <class> <grep-args...> — scan $f for one leak class; a scan error
# fails closed like a hit. _sclass <class> <filter> <-o grep-args...> is the
# --strict form: <filter> drops placeholder hits first.
_class() {
    local label="$1" hits rc; shift
    hits="$(_scan "$f" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        _report "$label" "$hits"
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi
}
_sclass() {
    local label="$1" filter="$2" hits rc; shift 2
    hits="$(_scan "$f" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        hits="$(printf '%s\n' "$hits" | "$filter")"
        [ -n "$hits" ] && _report "$label" "$hits"
    elif [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    fi
    return 0
}

for f in ${FILES[@]+"${FILES[@]}"}; do
    case "$f" in
        */check-sanitization.sh | check-sanitization.sh) continue ;;
    esac
    # Fail closed: a named target that is missing or not a readable regular
    # file is an error, not a silent skip.
    if [ "$f" = "-" ]; then
        STDIN_TEXT="$(cat)"
    elif [ ! -f "$f" ] || [ ! -r "$f" ]; then
        echo "$prog: FAIL: $f — missing or unreadable; failing closed"
        FAIL=1
        continue
    fi

    # Personal macOS home path — any /Users/<name>/ (no carve-out). Case-
    # insensitive, matched per occurrence so a mixed-content line cannot hide it.
    # --strict drops the trailing-slash requirement.
    if [ -n "$STRICT" ]; then
        _sclass "personal macOS home path" _home_real -nioE "/Users/$NAME"
    else
        _class "personal macOS home path" -nioE '/Users/[^/]+/'
    fi

    # Personal Linux home path — every /home/<name>/ occurrence except exactly
    # /home/ubuntu/ (bare /home/ubuntu under --strict). Per occurrence (not per
    # line), so /home/ubuntu/ok beside /home/bob/x on one line still trips; a
    # /home/ubuntu/../ traversal that escapes the allowed segment also trips.
    if [ -n "$STRICT" ]; then
        lin="/home/$NAME" ok=':/home/ubuntu$'
    else
        lin='/home/[^/]+/' ok=':/home/ubuntu/$'
    fi
    hits="$(_scan "$f" -nioE "$lin")"; rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "$prog: FAIL: $f — could not scan (grep exit $rc); failing closed"
        FAIL=1
    elif [ "$rc" -eq 0 ]; then
        if [ -n "$STRICT" ]; then
            bad="$(printf '%s\n' "$hits" | _home_trim | grep -vE "$ok" | _home_real)"
        else
            bad="$(printf '%s\n' "$hits" | grep -vE "$ok")"
        fi
        trav="$(_scan "$f" -nioE '/home/[^/]+/\.\.')"
        both="$(printf '%s\n%s\n' "$bad" "$trav" | grep -v '^$')"
        [ -n "$both" ] && _report "personal Linux home path" "$both"
    fi

    _class "Slack token" -nE 'xox[bapr]-'
    _class "private key material" -n -- '-----BEGIN .*PRIVATE KEY-----'

    if [ -n "$STRICT" ]; then
        _sclass "personal Windows home path" _home_real -nioE "[a-z]:\\\\Users\\\\$NAME"
        _class "GitHub token" \
            -nE '(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
        _class "API key" -nE '(^|[^A-Za-z0-9_-])(sk-ant-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,})'
        _class "AWS key" -nE '(^|[^A-Z0-9])AKIA[0-9A-Z]{16}'
        _class "bearer token" -nE 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
        _sclass "credential assignment" _cred_real \
            -nioE '(KEY|TOKEN|SECRET|PASSWORD)[[:space:]]*[=:][[:space:]]*[^[:space:]]{16,}'
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "$prog: FAILED"
    exit 1
fi
echo "$prog: OK"
