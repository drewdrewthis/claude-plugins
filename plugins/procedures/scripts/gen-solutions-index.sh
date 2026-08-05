#!/usr/bin/env bash
# gen-solutions-index.sh — rebuild references/solutions/INDEX.md from the
# solution records in references/solutions/*.md (excluding INDEX.md itself).
#
# Mirror of scripts/gen-common-mistakes.sh / scripts/gen-common-procedures.sh.
# INDEX.md is a MATERIALIZED view: the source of truth is the individual
# solution record files. This script DERIVES the index from them, newest
# record (by filename date prefix) first.
#
# Row format matches the pre-existing hand-maintained INDEX.md:
#   | [file-stem](file.md) | <title, with leading "#" stripped> |
# Title resolution (see scripts/lib/gen-index-lib.sh): frontmatter `title:`
# field > first H1 > filename slug.
#
# Idempotent: running twice on a clean tree produces a byte-identical file.
#
# Usage:
#   scripts/gen-solutions-index.sh           # writes references/solutions/INDEX.md
#   scripts/gen-solutions-index.sh --stdout  # writes to stdout, never touches the tree

set -uo pipefail

STDOUT_MODE=0
[ "${1:-}" = "--stdout" ] && STDOUT_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PLUGIN ADAPTATION: data root defaults to the host codex (~/.claude), not this
# plugin install dir — upstream these scripts live inside the codex repo itself.
ROOT="${CODEX_ROOT:-$HOME/.claude}"
cd "$ROOT"

# shellcheck source=lib/gen-index-lib.sh
source "$SCRIPT_DIR/lib/gen-index-lib.sh"

DIR="${SOLUTIONS_DIR:-references/solutions}"
OUT="$DIR/INDEX.md"
BANNER='DO NOT EDIT — regenerate with scripts/gen-solutions-index.sh'

BODY="$(gen_index_render "$DIR" "$BANNER" "Solutions index" "Solution" "solution" "gen-solutions-index.sh")"
COUNT="$(printf '%s\n' "$BODY" | grep -c '^| \[')"

if [ "$STDOUT_MODE" -eq 1 ]; then
    printf '%s\n' "$BODY"
else
    printf '%s\n' "$BODY" > "$OUT"
    echo "gen-solutions-index: wrote $OUT ($COUNT solution rows)" >&2
fi
exit 0
