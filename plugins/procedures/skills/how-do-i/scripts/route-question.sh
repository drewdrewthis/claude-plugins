#!/usr/bin/env bash
# Tenant knowledge router: search the four knowledge surfaces best-first and
# print ranked hits (path + first matching line). Read the winning doc before
# answering — this prints pointers, not answers.
set -uo pipefail

q="$*"
[ -n "$q" ] || { echo "usage: route-question.sh <question words>"; exit 2; }

REFS="${KNOWLEDGE_REFS:-$HOME/.claude/references}"
PROCS="$REFS/procedures"
SOLUTIONS="$REFS/solutions"
PRINCIPLES="$REFS/principles"
FAILMODES="$REFS/failure-modes"
DECISIONS="${KNOWLEDGE_DECISIONS:-$REFS/decisions.jsonl}"
MISTAKES="${KNOWLEDGE_MISTAKES:-$REFS/mistakes.jsonl}"
SHIPPED="${HOW_DO_I_EXTRA_DOCS:-}"
RECALL="${RECALL_SCRIPT:-$HOME/.claude/skills/recall/scripts/recall.sh}"

# Build a grep alternation from the meaningful words (drop stopwords/short).
words=$(echo "$q" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '\n' \
  | grep -vE '^(how|do|i|the|a|an|to|for|is|are|we|my|of|in|on|it|what|when|did|have|has|was)$' \
  | grep -E '.{3,}' | sort -u | paste -sd'|')
[ -n "$words" ] || words=$(echo "$q" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '|')

hit=0
section() { echo; echo "== $1 =="; }

section "procedures ($PROCS)"
if [ -d "$PROCS" ]; then
  grep -ril -E "$words" "$PROCS" 2>/dev/null | head -5 | while read -r f; do
    echo "$f"
    grep -im1 -E "$words" "$f" | sed 's/^/    > /'
    hit=1
  done
else
  echo "(none written yet)"
fi

section "solutions ($SOLUTIONS)"
if [ -d "$SOLUTIONS" ]; then
  grep -ril -E "$words" "$SOLUTIONS" 2>/dev/null | head -5 | while read -r f; do
    echo "$f"
    grep -im1 -E "$words" "$f" | sed 's/^/    > /'
  done
else
  echo "(none written yet)"
fi

for pair in "principles:$PRINCIPLES" "failure-modes:$FAILMODES"; do
  label="${pair%%:*}"; dir="${pair#*:}"
  if [ -d "$dir" ]; then
    section "$label ($dir)"
    grep -ril -E "$words" "$dir" 2>/dev/null | head -5 | while read -r f; do
      echo "$f"
      grep -im1 -E "$words" "$f" | sed 's/^/    > /'
    done
  fi
done

section "decisions ($DECISIONS)"
if [ -f "$DECISIONS" ]; then
  grep -i -E "$words" "$DECISIONS" 2>/dev/null | tail -5 | cut -c1-200
else
  echo "(no decisions logged yet)"
fi

if [ -n "$SHIPPED" ] && [ -d "$SHIPPED" ]; then
  section "shipped docs ($SHIPPED)"
  grep -ril -E "$words" "$SHIPPED" 2>/dev/null | head -5 | while read -r f; do
    echo "$f"
    grep -im1 -E "$words" "$f" | sed 's/^/    > /'
  done
fi

section "mistakes ($MISTAKES)"
if [ -f "$MISTAKES" ]; then
  grep -i -E "$words" "$MISTAKES" 2>/dev/null | tail -5 | cut -c1-200
else
  echo "(no mistakes logged yet)"
fi

section "history (/recall)"
if [ -x "$RECALL" ] || [ -f "$RECALL" ]; then
  bash "$RECALL" "$q" 2>/dev/null | head -12 || echo "(recall unavailable)"
else
  echo "(recall unavailable)"
fi
