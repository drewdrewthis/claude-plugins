#!/usr/bin/env bash
# SessionStart hook — load the tenant's working context into the session:
# who their person is (ABOUT_MY_PERSON.md) + today's and the previous daily
# note. Output goes to stdout → injected as context. Fail-open: never block
# a session over a missing file.
set -uo pipefail

WS="${KNOWLEDGE_WS:-$HOME/workspace}"
ABOUT="$WS/references/docs/ABOUT_MY_PERSON.md"
NOTES="$WS/notes"

if [ -s "$ABOUT" ]; then
  echo "## Who your person is (references/docs/ABOUT_MY_PERSON.md — maintain via /about-my-person)"
  cat "$ABOUT"
  echo
fi

today="$NOTES/$(date +%F).md"
prev=$(ls "$NOTES"/????-??-??.md 2>/dev/null | grep -v "^$today$" | sort | tail -1 || true)

if [ -s "$today" ]; then
  echo "## Daily note (today — append via /take-note)"
  cat "$today"
  echo
elif [ -n "${prev:-}" ] && [ -s "$prev" ]; then
  echo "## Daily note (previous day — no note yet today; /take-note rolls over)"
  cat "$prev"
  echo
fi

exit 0
