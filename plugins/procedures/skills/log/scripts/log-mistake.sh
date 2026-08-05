#!/usr/bin/env bash
# log-mistake.sh — deterministic writer for /log mistake.
#
# Appends ONE JSON line to $KNOWLEDGE_REFS/mistakes.jsonl (or
# $KNOWLEDGE_MISTAKES if set). Built with jq -n, never an inline echoed
# brace-literal — the apostrophe-in-jq bug class. The skill owns the judgment
# (field values, finding the recurrence_of ancestor); this owns the mechanics.
#
# Usage:
#   log-mistake.sh --category wrong-assumption --description "..." \
#     --correction "..." --severity medium --trigger human \
#     [--recurrence-of "<ts of earliest same-pattern entry>"]
#
# No CLAUDE.md compilation happens here — a plugin does not own the host
# CLAUDE.md. Recurring mistakes surface through /how-do-i (mistakes surface)
# and belong in scout/handoff briefings.

set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "log-mistake: jq required" >&2; exit 1; }

CATEGORY= DESCRIPTION= CORRECTION= SEVERITY= TRIGGER= RECURRENCE_OF=
while [ $# -gt 0 ]; do
  case "$1" in
    --category)      CATEGORY="$2"; shift 2 ;;
    --description)   DESCRIPTION="$2"; shift 2 ;;
    --correction)    CORRECTION="$2"; shift 2 ;;
    --severity)      SEVERITY="$2"; shift 2 ;;
    --trigger)       TRIGGER="$2"; shift 2 ;;
    --recurrence-of) RECURRENCE_OF="$2"; shift 2 ;;
    *) echo "log-mistake: unknown arg $1" >&2; exit 2 ;;
  esac
done

for v in CATEGORY DESCRIPTION CORRECTION SEVERITY TRIGGER; do
  [ -n "${!v}" ] || { echo "log-mistake: missing --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; exit 2; }
done
case "$CATEGORY" in
  wrong-action|wrong-assumption|forgot-instruction|wasted-work|wrong-tool|wrong-model|style-violation|other) ;;
  *) echo "log-mistake: bad category '$CATEGORY'" >&2; exit 2 ;;
esac
case "$SEVERITY" in low|medium|high) ;; *) echo "log-mistake: bad severity '$SEVERITY'" >&2; exit 2 ;; esac
case "$TRIGGER" in human|self) ;; *) echo "log-mistake: bad trigger '$TRIGGER'" >&2; exit 2 ;; esac

OUT="${KNOWLEDGE_MISTAKES:-${KNOWLEDGE_REFS:-$HOME/.claude/references}/mistakes.jsonl}"
mkdir -p "$(dirname "$OUT")"

jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg category "$CATEGORY" \
  --arg description "$DESCRIPTION" \
  --arg correction "$CORRECTION" \
  --arg severity "$SEVERITY" \
  --arg trigger "$TRIGGER" \
  --arg rec "$RECURRENCE_OF" \
  '{ts:$ts, category:$category, description:$description, correction:$correction,
    severity:$severity, trigger:$trigger,
    recurrence_of:(if $rec == "" then null else $rec end)}' >> "$OUT"

echo "logged: $OUT ($CATEGORY/$SEVERITY$([ -n "$RECURRENCE_OF" ] && echo ", recurrence"))"
