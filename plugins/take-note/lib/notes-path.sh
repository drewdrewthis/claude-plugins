#!/usr/bin/env bash
# notes-path.sh — shared daily-note path resolution for the take-note plugin.
# Sourced by both the SessionStart hook (hooks/load-daily-note.sh) and the
# skill script (skills/take-note/scripts/note-file.sh) so the two never drift.
#
# SINGLE RESPONSIBILITY: resolve where daily notes live and which file is
# "today" / "the previous day". No I/O side effects beyond reading the
# filesystem — callers own mkdir, existence checks, and output formatting.

WS="${KNOWLEDGE_WS:-$HOME/workspace}"
NOTES_DIR="${NOTES_DIR:-$WS/notes}"

# notes_today_file — echoes today's daily-note path.
notes_today_file() {
  echo "$NOTES_DIR/$(date +%F).md"
}

# notes_prev_file — echoes the newest daily-note file in NOTES_DIR that is
# not today's file; empty output if none. Uses a fixed-string, whole-line
# match (grep -vFx) against the full path, not a regex.
notes_prev_file() {
  local today
  today="$(notes_today_file)"
  ls "$NOTES_DIR"/????-??-??.md 2>/dev/null | grep -vFx "$today" | sort | tail -1 || true
}
