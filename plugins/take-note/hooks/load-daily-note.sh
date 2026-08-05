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

today="$(notes_today_file)"
prev="$(notes_prev_file)"

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
