#!/usr/bin/env bash
# PLUGIN ADAPTATION: no upstream counterpart — librarian drain machinery.
# librarian-advance.sh — the only supported way to move a librarian cursor.
#
#   bash librarian-advance.sh <slug> <end>
#
# Its caller is hooks/librarian-poke.sh, which advances every issued range to its
# end after a librarian wake exits 0; the librarian model never runs it.
#
# Sets <state-dir>/cursors/<slug>.line to <end>, but only within the range the
# current batch issued for <slug> (<state-dir>/batch.manifest, written by
# librarian-batch.sh): <end> may not exceed the issued end, so a cursor can
# never move over lines that were not handed out to be read. It may not go
# below the current cursor either, unless the batch issued the transcript from
# 0 (the truncation reset). Refuses with a message and exit 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/stores.sh
. "$SCRIPT_DIR/lib/stores.sh" 2>/dev/null || true
STATE="$(procedures_state_dir)"
MANIFEST="$STATE/batch.manifest"

_refuse() { printf 'librarian-advance: REFUSED: %s\n' "$1" >&2; exit 1; }

[ $# -eq 2 ] || { printf 'usage: librarian-advance.sh <slug> <end>\n' >&2; exit 2; }
slug="$1" end="$2"
case "$slug" in ''|*/*) _refuse "bad slug '$slug'" ;; esac
case "$end" in ''|*[!0-9]*) _refuse "end '$end' is not a line number" ;; esac
[ -f "$MANIFEST" ] || _refuse "no batch manifest at $MANIFEST — run librarian-batch.sh first"

issued="$(awk -F'\t' -v s="$slug" '$1 == s { print $2 "\t" $3; exit }' "$MANIFEST")"
[ -n "$issued" ] || _refuse "$slug was not issued in the current batch"
start="${issued%%$'\t'*}" issued_end="${issued#*$'\t'}"

cursor="$STATE/cursors/$slug.line"
cur=0
[ -f "$cursor" ] && cur="$(tr -dc '0-9' < "$cursor")"
cur="${cur:-0}"

[ "$end" -le "$issued_end" ] || _refuse "$slug: end $end is past the issued end $issued_end"
[ "$end" -ge "$start" ] || _refuse "$slug: end $end is before the issued start $start"
if [ "$end" -lt "$cur" ] && [ "$start" -ne 0 ]; then
    _refuse "$slug: end $end would move the cursor back from $cur"
fi

mkdir -p "$STATE/cursors"
printf '%s\n' "$end" > "$cursor.tmp"
mv "$cursor.tmp" "$cursor"
printf 'librarian-advance: %s -> %s\n' "$slug" "$end"
