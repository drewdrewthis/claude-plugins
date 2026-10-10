#!/usr/bin/env bash
# PLUGIN ADAPTATION: no upstream counterpart — librarian drain machinery.
# librarian-batch.sh — issue ONE bounded batch of unread transcript lines for a
# librarian drain, so a backlog is read in full across drains instead of being
# sampled in one.
#
#   bash librarian-batch.sh [--out FILE] [--pressure-check PATH]
#
# Picks transcripts under ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/*.jsonl the
# same way the librarian always has: mtime within 7 days, line count greater
# than the cursor, and a cursor past the end (truncation/compaction) resets to
# 0. Oldest transcript first. Each unread line is distilled to readable text
# (user/assistant text; tool calls and results clipped) and appended to the
# batch until LIBRARIAN_BATCH_BYTES (default 200000) of text is reached. The
# batch always ends on a line boundary, so one giant transcript is split across
# drains with no gap or overlap. A line that fails to parse, or carries no
# text, is skipped but still counts as read.
#
# Writes the batch to FILE (default <state-dir>/batch.txt — Bash tool output is
# truncated, so the librarian Reads the file) and the issued ranges to
# <state-dir>/batch.manifest, one `slug<TAB>start<TAB>end` per transcript: lines
# start+1..end were issued. Cursors are advanced by the poke hook via
# librarian-advance.sh, only within the range issued here.
#
# --pressure-check PATH: every LIBRARIAN_RECHECK_SECS (default 5; 0 = every
# iteration) run `bash PATH --load-ok`; when it exits 75 the batch removes its
# partial output and exits 75 (pressure-check abort), so no manifest is left.
# Any other exit means proceed. Prints a one-line summary; exit 0 with an empty manifest
# means there is nothing to drain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/stores.sh
. "$SCRIPT_DIR/lib/stores.sh" 2>/dev/null || true
STATE="$(procedures_state_dir)"
CURSORS="$STATE/cursors"
MANIFEST="$STATE/batch.manifest"
# Drop the previous manifest before anything can fail: an aborted run must
# never leave stale ranges for librarian-advance.sh to honour. The new one is
# written to a temp file and moved into place only on success.
rm -f "$MANIFEST"
OUT="$STATE/batch.txt"
BUDGET="${LIBRARIAN_BATCH_BYTES:-200000}"
CLIP=300
CHECK=""
RECHECK="${LIBRARIAN_RECHECK_SECS:-5}"
case "$RECHECK" in ''|*[!0-9]*) RECHECK=5 ;; esac

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --pressure-check) CHECK="$2"; shift 2 ;;
        *) printf 'librarian-batch: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
case "$BUDGET" in ''|0*|*[!0-9]*) printf 'librarian-batch: LIBRARIAN_BATCH_BYTES must be a positive integer\n' >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'librarian-batch: jq is required\n' >&2; exit 2; }

mkdir -p "$CURSORS"
: > "$OUT"
: > "$MANIFEST.tmp"

# _first_line <file> — print the first line; fails when the file has none. The
# `-n` guard keeps a last line that has no trailing newline.
_first_line() {
    local first=""
    IFS= read -r first < "$1" 2>/dev/null || [ -n "$first" ] || return 1
    printf '%s' "$first"
}

# _is_librarian <first-line> — 0 when it is a `claude -p --agent
# procedures:librarian` session. Claude Code writes that as the first line:
# {"type":"agent-setting","agentSetting":"procedures:librarian",...}. jq runs
# only when the line looks like an agent-setting.
_is_librarian() {
    case "$1" in *'"agent-setting"'*) ;; *) return 1 ;; esac
    [ "$(printf '%s\n' "$1" | jq -r 'select(.type == "agent-setting") | .agentSetting' 2>/dev/null)" = "procedures:librarian" ]
}

# _is_judge <first-line> — 0 when it is a worklog judge `claude -p` run, whose
# first line is the enqueue record of its CANDIDATES prompt. That text is the
# judge's input, not a session. Same jq-only-on-a-hit shape as above.
# The heading literal copies the judge prompt heading in
# plugins/worklog/hooks/worklog-record.sh; the two must change together. The
# judge now runs with --no-session-persistence, so this skip only covers
# transcripts saved before that.
_is_judge() {
    case "$1" in *'"queue-operation"'*'CANDIDATES (uuid, where, kind, text):'*) ;; *) return 1 ;; esac
    printf '%s\n' "$1" | jq -e 'select(.type == "queue-operation" and .operation == "enqueue")
        | .content | strings | startswith("CANDIDATES (uuid, where, kind, text):")' >/dev/null 2>&1
}

_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# Exactly one output line per input line — awk numbers lines by position, so
# a line that emitted nothing would misnumber every later one. The distilled
# text has newlines folded to \x1e (unfolded by awk below); an unparseable,
# text-free or unexpectedly shaped line yields "" (the try/catch guarantees it).
# shellcheck disable=SC2016
DISTILL='
def clip($n): tostring | if length > $n then .[0:$n] + "…[+\(length - $n) chars]" else . end;
def blocks: if type == "string" then (if . == "" then [] else [{type: "text", text: .}] end)
  elif type == "array" then map(if type == "string" then {type: "text", text: .} elif type == "object" then . else empty end)
  else [] end;
def flat: if type == "string" then . elif type == "array" then map(.text? // tostring) | join(" ") else tostring end;
try (
  (try fromjson catch null) as $j
  | if ($j | type) != "object" or (($j.type // "") | IN("user", "assistant") | not) then ""
    else $j.type as $t
    | [ (($j.message | objects | .content) // "" | blocks)[]
        | if .type == "text" then "\($t): \(.text // "" | clip($budget))"
          elif .type == "tool_use" then "\($t) tool_use \(.name // "?"): \(.input | tojson | clip($clip))"
          elif .type == "tool_result" then "tool_result: \(.content | flat | clip($clip))"
          else empty end ]
    | join("\n")
    end
  | gsub("\u001e"; " ") | gsub("\n"; "\u001e")
) catch ""'

used=0
last_check=$SECONDS
while IFS=$'\t' read -r _ f; do
    if [ -n "$CHECK" ] && [ $(( SECONDS - last_check )) -ge "$RECHECK" ]; then
        last_check=$SECONDS
        # </dev/null: the check must not eat the file list this loop reads.
        rc=0; bash "$CHECK" --load-ok </dev/null || rc=$?
        if [ "$rc" -eq 75 ]; then
            rm -f "$OUT.part" "$MANIFEST.tmp"
            printf 'librarian-batch: deferred, pressure check asked to stop\n' >&2
            exit 75
        fi
    fi
    [ "$used" -lt "$BUDGET" ] || break
    slug="$(basename "$f" .jsonl)"
    first="$(_first_line "$f")" || first=""
    _is_librarian "$first" && continue       # the librarian's own drains: never issued, no cursor
    _is_judge "$first" && continue           # the worklog judge's runs: same
    total="$(wc -l < "$f" 2>/dev/null | tr -d ' ')" || continue   # vanished/unreadable since find
    [ -n "$total" ] || continue
    cur=0
    [ -f "$CURSORS/$slug.line" ] && cur="$(tr -dc '0-9' < "$CURSORS/$slug.line")"
    cur="${cur:-0}"
    [ "$total" -lt "$cur" ] && cur=0          # truncated/compacted: re-read from the start
    [ "$total" -gt "$cur" ] || continue

    # awk emits the kept text and, last, "END <last line issued> <bytes used>".
    # awk exiting early on the budget SIGPIPEs jq/head/tail: 141 from those is
    # expected. Any other failure, or a malformed END, skips this transcript
    # with no range issued (its cursor stays put) instead of stalling the batch.
    set +e
    tail -n "+$((cur + 1))" "$f" | head -n "$((total - cur))" \
        | jq -R -r --argjson clip "$CLIP" --argjson budget "$BUDGET" "$DISTILL" \
        | LC_ALL=C awk -v start="$cur" -v used="$used" -v budget="$BUDGET" \
            -v hdr="=== $slug ($f) ===" '
            { n = start + NR; t = $0
              if (t == "") { last = n; next }
              gsub(/\036/, "\n", t); line = "[L" n "] " t "\n"
              cost = length(line) + (printed ? 0 : length(hdr) + 1)
              if (used + cost > budget && used > 0) exit
              if (!printed) { printf "%s\n", hdr; printed = 1 }
              printf "%s", line; used += cost; last = n }
            END { printf "END %d %d\n", (last ? last : start), used }' > "$OUT.part"
    ps=("${PIPESTATUS[@]}")
    set -e
    ok=1
    for k in 0 1 2; do case "${ps[$k]}" in 0|141) ;; *) ok=0 ;; esac; done
    [ "${ps[3]}" = 0 ] || ok=0
    read -r tag end new_used < <(tail -n 1 "$OUT.part") || true
    case "$tag:$end:$new_used" in END:[0-9]*:[0-9]*) ;; *) ok=0 ;; esac
    case "$end$new_used" in *[!0-9]*) ok=0 ;; esac
    if [ "$ok" != 1 ]; then
        printf 'librarian-batch: skipped %s: distill failed (tail/head/jq/awk exit %s)\n' "$f" "${ps[*]}" >&2
        continue
    fi
    used="$new_used"
    sed '$d' "$OUT.part" >> "$OUT"
    [ "$end" -gt "$cur" ] || break            # budget already spent before this transcript
    printf '%s\t%s\t%s\n' "$slug" "$cur" "$end" >> "$MANIFEST.tmp"
    [ "$end" -eq "$total" ] || break          # split mid-transcript: the rest is the next batch
done < <(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -mindepth 2 -maxdepth 2 \
            -name '*.jsonl' -mtime -7 2>/dev/null \
         | while IFS= read -r f; do printf '%s\t%s\n' "$(_mtime "$f")" "$f"; done \
         | sort -n -k1,1)

rm -f "$OUT.part"
mv "$MANIFEST.tmp" "$MANIFEST"
printf 'librarian-batch: %s transcript range(s), %s bytes -> %s (manifest %s)\n' \
    "$(wc -l < "$MANIFEST" | tr -d ' ')" "$used" "$OUT" "$MANIFEST"
