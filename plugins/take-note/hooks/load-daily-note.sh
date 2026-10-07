#!/usr/bin/env bash
# SessionStart hook — load the tenant's working context into the session:
# who their person is (ABOUT_MY_PERSON.md) + today's and the previous daily
# note. Output goes to stdout → injected as context. Fail-open: never block
# a session over a missing file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=../lib/notes-path.sh
source "$SCRIPT_DIR/../lib/notes-path.sh" || exit 0

ABOUT="${ABOUT_MY_PERSON_FILE:-${ABOUT_MY_PERSON_DIR:-$HOME/.claude/about-my-person}/ABOUT_MY_PERSON.md}"

if [ -s "$ABOUT" ]; then
  echo "## Who your person is ($ABOUT — maintain via /about-my-person)"
  cat "$ABOUT"
  echo
fi

# Load exactly ONE file: today's if it has content, else the previous day's if
# it has content, else nothing. The loader is capped — an open-item index plus
# the file's tail — so a long shared note cannot flood the session context.
chosen=""
label=""
today="$(notes_today_file)"
if [ -s "$today" ]; then
  chosen="$today"
else
  prev="$(notes_prev_file)"
  if [ -n "${prev:-}" ] && [ -s "$prev" ]; then
    chosen="$prev"
    label=" (previous day — no note yet today)"
  fi
fi

if [ -n "$chosen" ]; then
  total="$(wc -l < "$chosen" | tr -d ' ')"
  echo "## Work notes (shared by every agent on this machine) — $chosen$label"
  echo "Open items:"
  items="$(notes_open_items "$chosen")"
  if [ -n "$items" ]; then
    printf '%s\n' "$items" | sed 's/^/- /'
  else
    echo "- none"
  fi
  echo "Last 20 lines (of $total):"
  tail -n 20 "$chosen"
  echo
  echo "Read the full file when your task touches other work. Write via /take-note."
fi

exit 0
