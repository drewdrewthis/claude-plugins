#!/usr/bin/env bash
# Resolve today's daily-note file for the tenant workspace.
# Prints TODAY=<path> PREV=<path|none> NEW=<yes|no>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../lib/notes-path.sh
source "$SCRIPT_DIR/../../../lib/notes-path.sh"

mkdir -p "$NOTES_DIR"

today="$(notes_today_file)"
prev="$(notes_prev_file)"

echo "TODAY=$today"
echo "PREV=${prev:-none}"
if [ -e "$today" ]; then echo "NEW=no"; else echo "NEW=yes"; fi
