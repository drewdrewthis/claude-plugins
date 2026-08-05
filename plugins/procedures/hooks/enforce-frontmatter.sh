#!/usr/bin/env bash
# enforce-frontmatter.sh — PostToolUse hook (matcher: Write|Edit).
#
# SINGLE RESPONSIBILITY: every markdown record written into a knowledge store
# must carry the six-key frontmatter schema (id, kind, date, keywords, links,
# status). Runs the vendored lint-frontmatter.sh on the file just written; a
# violation exits 2 so the agent is told to fix it immediately, while the
# write itself has already landed (PostToolUse cannot and should not undo it).
#
# Scope: only .md files under the record stores beneath $KNOWLEDGE_ROOT
# (default ~/.claude). Templates, EVOLUTION.md, INDEX.md, steps/ are excluded
# by the linter's own predicate. Everything else: silent exit 0.
# FAIL-OPEN on machinery errors (no jq, unreadable input): a broken linter
# must not block writing.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
case "$FILE" in *.md) ;; *) exit 0 ;; esac
[ -f "$FILE" ] || exit 0

ROOT="${KNOWLEDGE_ROOT:-$HOME/.claude}"
case "$FILE" in "$ROOT"/*) ;; *) exit 0 ;; esac
REL="${FILE#"$ROOT"/}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
LINTER="$SCRIPT_DIR/../scripts/lint-frontmatter.sh"
[ -x "$LINTER" ] || exit 0

OUT="$(LINT_FRONTMATTER_ROOT="$ROOT" bash "$LINTER" "$REL" 2>&1)"
STATUS=$?
# Targeted mode errors on non-record targets ("not a lintable record") — that
# is out-of-scope for enforcement, not a violation.
if [ "$STATUS" -ne 0 ] && ! printf '%s' "$OUT" | grep -q 'not a lintable record'; then
    {
        echo "FRONTMATTER: $REL violates the record frontmatter schema. Fix it now:"
        printf '%s\n' "$OUT"
        echo "Every record needs the six keys: id, kind, date, keywords (non-empty), links, status."
    } >&2
    exit 2
fi
exit 0
