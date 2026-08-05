#!/usr/bin/env bash
# Resolve today's daily-note file for the tenant workspace.
# Prints TODAY=<path> PREV=<path|none> NEW=<yes|no>
set -euo pipefail

NOTES_DIR="${NOTES_DIR:-${KNOWLEDGE_WS:-$HOME/workspace}/notes}"
mkdir -p "$NOTES_DIR"

today="$NOTES_DIR/$(date +%F).md"
prev=$(ls "$NOTES_DIR"/????-??-??.md 2>/dev/null | grep -v "^$today$" | sort | tail -1 || true)

echo "TODAY=$today"
echo "PREV=${prev:-none}"
if [ -e "$today" ]; then echo "NEW=no"; else echo "NEW=yes"; fi
