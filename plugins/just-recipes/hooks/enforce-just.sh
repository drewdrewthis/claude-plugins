#!/bin/bash
# PreToolUse (Bash) hook: funnel raw bash through just where a justfile resolves.
# Defensive by design: ANY internal failure must result in exit 0 (allow).
# Never use `set -e` here — a hook that exits nonzero on a bug denies all Bash.

deny() {
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Raw bash is funneled through just here. Run 'just --list' to find a recipe, or use the escape hatch: just wrap \"<your command>\". To add a recipe: see the just-recipes skill."}}
JSON
  exit 0
}

# Kill switch
case "${JUST_RECIPES_ENFORCE:-}" in
  off|0) exit 0 ;;
esac

# just not installed -> passthrough
command -v just >/dev/null 2>&1 || exit 0

# Read stdin (hook input JSON); any failure -> allow
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Already a just invocation (word boundary)
case "$cmd" in
  just|just\ *|just$'\t'*) exit 0 ;;
esac

# Tiny read-only allowlist to avoid nuisance denials
if printf '%s' "$cmd" | grep -Eq '^[[:space:]]*(cd|pwd|echo|ls|cat|command -v|which)([[:space:]]|$)'; then
  exit 0
fi

# No justfile resolvable from the project dir (or cwd) -> passthrough
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
( cd "$dir" 2>/dev/null && just --summary >/dev/null 2>&1 ) || exit 0

deny
