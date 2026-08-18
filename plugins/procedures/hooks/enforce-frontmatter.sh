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

# Resolved WITHOUT the external `dirname`: this now runs before the jq check,
# and that path is exercised with PATH emptied entirely
# (enforce-frontmatter.bats "jq-less PATH"). `${x%/*}` is parameter expansion
# and `cd`/`pwd` are builtins, so nothing here needs PATH — same shape as the
# two gates.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0

# PLUGIN ADAPTATION: this check's own off-switch — userConfig
# `enable_frontmatter_check`, on by default. See lib/gate-escape.sh. Sourced
# here, CALLED below the scope filters: the switch is evaluated only once this
# hook knows the write is a record it would have linted, so the escape record
# means "a check was released" and not "a Write happened somewhere on disk".
# An unreadable lib leaves the check ARMED.
# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
case "$FILE" in *.md) ;; *) exit 0 ;; esac
[ -f "$FILE" ] || exit 0

ROOT="${KNOWLEDGE_ROOT:-${CODEX_ROOT:-$HOME/.claude}}"
case "$FILE" in "$ROOT"/*) ;; *) exit 0 ;; esac
REL="${FILE#"$ROOT"/}"

LINTER="$SCRIPT_DIR/../scripts/lint-frontmatter.sh"
[ -x "$LINTER" ] || exit 0

OUT="$(LINT_FRONTMATTER_ROOT="$ROOT" bash "$LINTER" "$REL" 2>&1)"
STATUS=$?
# Targeted mode errors on non-record targets ("not a lintable record") — that
# is out-of-scope for enforcement, not a violation.
#
# Matched with `case`, not `printf | grep -q`: grep exits on its first match,
# the still-writing printf takes SIGPIPE, and pipefail reports 141 for a
# SUCCESSFUL match once the linter's output outgrows the pipe buffer. The
# marker is printed on line 1, so a verbose run matched early and blocked an
# out-of-scope write (#46, hooks/tests/frontmatter-sigpipe.bats).
case "$OUT" in
    *"not a lintable record"*) OUT_OF_SCOPE=1 ;;
    *) OUT_OF_SCOPE=0 ;;
esac
if [ "$STATUS" -ne 0 ] && [ "$OUT_OF_SCOPE" -eq 0 ]; then
    # A real violation: this check WOULD have fired. Only here does the switch
    # matter, and only here is a release worth recording. Anywhere above, the
    # record-store predicate has not run yet — it lives inside the linter — so
    # most .md under $ROOT (CLAUDE.md, agents/*.md, SKILL.md, templates/) would
    # log a release nothing was ever going to block.
    if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "FRONTMATTER_CHECK"; then exit 0; fi
    {
        echo "FRONTMATTER: $REL violates the record frontmatter schema. Fix it now:"
        printf '%s\n' "$OUT"
        echo "Every record needs the six keys: id, kind, date, keywords (non-empty), links, status."
    } >&2
    exit 2
fi
exit 0
