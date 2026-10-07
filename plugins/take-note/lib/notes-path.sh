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
# when the heading ends with " — done" (em dash); "### Scratch" (any case,
# trailing whitespace ok) is not an item. grep/sed only, portable to bash 3.2
# and BSD userland; the em dash is a plain byte match, so any locale works.
notes_open_items() {
  local file="$1"
  [ -s "$file" ] || return 0
  grep '^### ' "$file" \
    | grep -v ' — done$' \
    | grep -v '^### [Ss]cratch[[:space:]]*$' \
    | sed 's/^### //' \
    || true
}

# notes_latest_entries <file> <n> — echoes the n newest entries in the file,
# oldest first. An entry is a line "- HH:MM ..."; each is suffixed with
# " (<heading>)", the last "### " heading above it. Ordered by HH:MM, ties by
# file position, so one busy item cannot hide the others' latest lines.
notes_latest_entries() {
  local file="$1" n="$2"
  [ -s "$file" ] || return 0
  awk '
    /^### / { h = substr($0, 5); next }
    /^- [0-9][0-9]:[0-9][0-9] / {
      printf "%s\t%d\t%s%s\n", substr($0, 3, 5), NR, $0, (h != "" ? " (" h ")" : "")
    }
  ' "$file" | sort -t "$(printf '\t')" -k1,1 -k2,2n | tail -n "$n" | cut -f3-
}

# notes_uncarried_items <prev> <today> — open items of prev whose heading is
# not a "### " heading in today (a trailing " — done" is ignored on today's side).
notes_uncarried_items() {
  local prev="$1" today="$2"
  notes_open_items "$prev" | grep -vxFf <(notes_open_items_any "$today") || true
}

# notes_open_items_any <file> — every "### " heading text, " — done" stripped.
notes_open_items_any() {
  [ -s "$1" ] || return 0
  grep '^### ' "$1" | sed -e 's/^### //' -e 's/ — done$//' || true
}
