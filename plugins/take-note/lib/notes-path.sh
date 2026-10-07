#!/usr/bin/env bash
# notes-path.sh — shared daily-note path resolution for the take-note plugin.
# Sourced by both the SessionStart hook (hooks/load-daily-note.sh) and the
# skill script (skills/take-note/scripts/note-file.sh) so the two never drift.
#
# SINGLE RESPONSIBILITY: resolve where daily notes live and which file is
# "today" / "the previous day". No I/O side effects beyond reading the
# filesystem — callers own mkdir, existence checks, and output formatting.

# Notes live under ~/agent-resources/ — the machine-wide home for agent
# resources shared across every tenant. NOTES_DIR is the only override.
NOTES_DIR="${NOTES_DIR:-$HOME/agent-resources/notes}"

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

# notes_open_items <file> — echoes each OPEN item's heading text, one per line,
# with the leading "### " stripped. An item is a "### " heading; it is CLOSED
# when the heading ends with " — done" (em dash); "### Scratch" is not an item.
# grep/sed only, portable to bash 3.2 and BSD userland (no GNU-only flags; the
# em dash is matched as its literal UTF-8 bytes, so callers must run in a UTF-8
# locale, which is the daily-note file's own encoding).
notes_open_items() {
  local file="$1"
  [ -s "$file" ] || return 0
  grep '^### ' "$file" \
    | grep -v ' — done$' \
    | grep -vx '### Scratch' \
    | sed 's/^### //' \
    || true
}
