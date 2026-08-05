#!/usr/bin/env bash
# gen-common-mistakes.sh — rebuild references/common-mistakes.md from the
# failure-modes/ record store + mistakes.jsonl recurrence counts.
#
# common-mistakes.md is the one MATERIALIZED view: it is @-imported by
# CLAUDE.md at session boot, so it must stay a valid, non-empty markdown table.
# The source of truth is the per-failure-mode records under
# references/failure-modes/; this script DERIVES the always-loaded distillate
# from them, ordered by recurrence (most-recurring first).
#
# Record contract (references/failure-modes/<id>.md):
#   - frontmatter with id, kind, date, keywords, links, status, AND a `rule:`
#     field — one crisp imperative sentence that is the entire table cell for
#     that row.
#   - a `## Mistake` section (human-readable description; not emitted here).
#   - a `## Correct` section (full correct behavior; not emitted here — read the
#     source record directly for the full guidance).
#   - FACE records (a face of a split mega-row) carry `face_of: <parent-id>` in
#     frontmatter and are NOT emitted as their own table row — they are the
#     normalized registry that /log links against; the parent row's
#     `rule:` already covers the faces. A PARENT record carries `mega: true`.
#
# Recurrence: counted from mistakes.jsonl `pattern` field. The 8 retired ids
# that merged into `unverified-claim-acted-on` (2026-06-10 condensation) fold
# into that spine. Malformed/variant jsonl lines are default-and-skipped with a
# tally printed to stderr (AC17) — never crash, never drop a well-formed count.
#
# Idempotent: running twice on a clean tree produces a byte-identical file.
#
# Usage:
#   scripts/gen-common-mistakes.sh           # writes references/common-mistakes.md
#   scripts/gen-common-mistakes.sh --stdout  # writes to stdout, never touches the tree

set -uo pipefail

STDOUT_MODE=0
[ "${1:-}" = "--stdout" ] && STDOUT_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PLUGIN ADAPTATION: data root defaults to the host codex (~/.claude), not this
# plugin install dir — upstream these scripts live inside the codex repo itself.
ROOT="${CODEX_ROOT:-$HOME/.claude}"
cd "$ROOT"

FM_DIR="references/failure-modes"
OUT="references/common-mistakes.md"
JSONL="${MISTAKES_JSONL:-$HOME/.claude/mistakes.jsonl}"
BANNER='DO NOT EDIT — regenerate with scripts/gen-common-mistakes.sh'

# ---- recurrence counts from jsonl (single python pass, default-and-skip malformed) ----
# Emits "<count>\t<pattern>" lines then a sentinel "skipped-malformed\t<n>" last line.
_PY_OUT="$(python3 - "$JSONL" <<'PY'
import json, sys
from collections import Counter
path = sys.argv[1]
MERGED = {
    'claim-done-without-evidence','speculation-with-false-precision',
    'dependency-conclusion-from-partial-read',
    'recipe-untested-because-test-bypasses-recipe','cross-layer-wire-untested',
    'stale-prove-it-marker-after-push','self-defeating-evidence-cmd','assumed-block',
}
SPINE = 'unverified-claim-acted-on'
c = Counter(); skipped = 0
try:
    fh = open(path)
except OSError:
    fh = []
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        skipped += 1
        continue
    p = o.get('pattern')
    if not p:
        continue
    if p in MERGED:
        p = SPINE
    c[p] += 1
for pat, n in c.items():
    print(f"{n}\t{pat}")
# Sentinel last line for the skipped count — parsed off before use.
print(f"skipped-malformed\t{skipped}")
PY
)"
# Split: last line is the sentinel; everything before is the recurrence table.
# awk instead of head -n -1 for macOS portability (BSD head rejects negative counts).
SKIPPED="$(printf '%s\n' "$_PY_OUT" | tail -1 | cut -f2)"
RECUR="$(printf '%s\n' "$_PY_OUT" | awk 'NR>1{print prev} {prev=$0}')"
unset _PY_OUT
echo "gen-common-mistakes: skipped $SKIPPED malformed jsonl line(s)" >&2

# recurrence lookup: pattern -> count (bash assoc)
declare -A RC=()
while IFS=$'\t' read -r n pat; do
    [ -n "${pat:-}" ] && RC["$pat"]="$n"
done <<< "$RECUR"

# ---- extract a `## <Section>` body (until next `## ` or EOF) from a record ----
section_body() {
    # $1 = file, $2 = section name
    awk -v sec="## $2" '
        $0==sec {grab=1; next}
        grab && /^## /{exit}
        grab {print}
    ' "$1" | awk 'NF{p=1} p' | sed -e 's/[[:space:]]*$//' | awk '
        # collapse to a single line (table cell), joining with spaces
        {lines[NR]=$0}
        END{
            out=""
            for(i=1;i<=NR;i++){
                if(lines[i]=="") continue
                out = (out=="") ? lines[i] : out " " lines[i]
            }
            print out
        }'
}

fm_value() {
    awk -v k="$2" 'NR==1{next} /^---$/{exit} $0 ~ "^"k":"{sub("^"k":[[:space:]]*",""); print; exit}' "$1"
}

# ---- collect parent/simple records (skip face records) ----
# Build sortable lines: "<recur>\t<rowid>\t<file>"
ROWS=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f" .md)"
    # skip face records (they roll up under their parent row)
    faceof="$(fm_value "$f" face_of)"
    [ -n "$faceof" ] && continue
    id="$(fm_value "$f" id)"; id="${id%%[[:space:]]*}"
    rowid="${id#fm.}"
    recur="${RC[$rowid]:-0}"
    printf -v line '%010d\t%s\t%s' "$recur" "$rowid" "$f"
    ROWS="${ROWS}${line}"$'\n'
done < <(find "$FM_DIR" -type f -name '*.md' 2>/dev/null | sort)

# ---- emit the file ----
{
    cat <<EOF
---
title: Common Mistakes
purpose: Distilled failure-mode flags — id + one-line rule. GENERATED from references/failure-modes/ records + mistakes.jsonl recurrence. Each row is a FLAG; the full description, sub-cases, canonical incidents, and file:line citations live in references/failure-modes/<id>.md and are reachable by grepping the id.
generated_by: scripts/gen-common-mistakes.sh
---

<!-- $BANNER -->

# Common Mistakes

The structured log lives at \`~/.claude/mistakes.jsonl\` (append-only). This file is the *distilled* set of recurring failure modes — one rule per row, scannable as a flag table. It is **generated**: the source of truth is the per-failure-mode records under \`references/failure-modes/\` (one file per mode, ranked here by recurrence). Edit a record + rerun \`scripts/gen-common-mistakes.sh\`; do not hand-edit this file.

\`/log\` matches a new correction against the \`failure-modes/\` records by \`id\`; the entry's \`pattern\` field links to the matched record id.

For the full description, sub-cases, canonical incidents, and file:line citations for any row, open \`references/failure-modes/<id>.md\` or grep the id.

## Universal

| Mistake | Rule |
|---------|------|
EOF
    # rows, recurrence desc then id asc
    printf '%s' "$ROWS" | awk 'NF' | sort -t$'\t' -k1,1nr -k2,2 | while IFS=$'\t' read -r _r rowid file; do
        rule="$(fm_value "$file" rule)"
        if [ -z "$rule" ]; then
            rule="$(section_body "$file" Correct | awk '{print $0; exit}')"
        fi
        rule="${rule#\"}"; rule="${rule%\"}"
        printf '| %s | %s |\n' "$rowid" "$rule"
    done
} | if [ "$STDOUT_MODE" -eq 1 ]; then
    cat
else
    cat > "$OUT"
    echo "gen-common-mistakes: wrote $OUT ($(grep -c '^| ' "$OUT") table lines incl header)" >&2
fi
exit 0
