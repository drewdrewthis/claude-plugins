#!/usr/bin/env bash
# check-sections.sh — per-kind required-section presence for records.
#
# The required sections per kind are the rubric in
# specs/RECORD_ADMISSIBILITY.md §Per-kind required sections. A "section" is a
# markdown heading (`#`..`######`) whose text contains the named phrase
# (case-insensitive substring). A kind with no entry has no requirement.
#
# WARN-first, mirroring lint-frontmatter.sh's LINT_DESCRIPTION_REQUIRED switch:
# a missing required section prints a WARN and exits 0 by DEFAULT; with
# LINT_SECTIONS_REQUIRED=1 the same record exits non-zero so commit-records.sh
# aborts. Templates already emit the sections, so tightening is a one-flag
# change later.
#
# Usage:
#   check-sections.sh <file> [file..]
#
# Pure bash/grep/awk; no network, no LLM.

set -uo pipefail

prog="check-sections"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/frontmatter.sh
source "$SCRIPT_DIR/lib/frontmatter.sh"

# _required_sections <kind> — print one required section phrase per line for a
# kind, nothing for an unlisted kind. SSOT: RECORD_ADMISSIBILITY.md.
_required_sections() {
    case "$1" in
        decision)     printf '%s\n' 'Goal' 'Chosen path' 'Outcome' ;;
        solution)     printf '%s\n' 'The problem shape' 'The fix' ;;
        failure-mode) printf '%s\n' 'Mistake' 'Correct' ;;
        procedure)    printf '%s\n' 'Steps' ;;
        *) : ;;
    esac
}

# _has_section <file> <phrase> — true iff the file has a heading line whose text
# contains <phrase> (case-insensitive).
_has_section() {
    grep -iE "^#{1,6}[[:space:]].*$2" "$1" >/dev/null 2>&1
}

REQUIRED="${LINT_SECTIONS_REQUIRED:-}"
FAIL=0

for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "$prog: ERROR: no such file: $f" >&2
        FAIL=1
        continue
    fi

    block="$(frontmatter_block "$f")"
    kind="$(fm_value "$block" kind)"
    kind="${kind%%[[:space:]]*}"
    [ -n "$kind" ] || continue

    while IFS= read -r section; do
        [ -n "$section" ] || continue
        if ! _has_section "$f" "$section"; then
            if [ -n "$REQUIRED" ]; then
                echo "$prog: FAIL: $f ($kind) — missing required section: $section"
                FAIL=1
            else
                echo "$prog: WARN: $f ($kind) — missing required section: $section"
            fi
        fi
    done < <(_required_sections "$kind")
done

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
