#!/usr/bin/env bash
# SessionStart hook — load working context into the session: who their person
# is (ABOUT_MY_PERSON.md) + ONE capped daily note (today's, else the newest
# previous) + the previous day's open items not yet carried to today. Output goes to stdout → injected as context. Fail-open: never block
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
# the 20 newest entries — so a long shared note cannot flood the session context.
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
  echo "Latest 20 entries (of $total lines):"
  notes_latest_entries "$chosen" 20
  if [ "$chosen" = "$today" ]; then
    prev="$(notes_prev_file)"
    if [ -n "${prev:-}" ]; then
      carry="$(notes_uncarried_items "$prev" "$today")"
      if [ -n "$carry" ]; then
        echo
        echo "Open items from $(basename "$prev" .md) (not carried over yet — add the heading to today's file when you touch it):"
        printf '%s\n' "$carry" | sed 's/^/- /'
      fi
    fi
  fi
  echo
  echo "Read the full file when your task touches other work. Write via /take-note."
fi

exit 0
