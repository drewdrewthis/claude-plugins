#!/usr/bin/env bash
# frontmatter.sh — single source of truth for reading YAML frontmatter in the
# codex lints.
#
# These two readers were byte-identical copies in scripts/lint-frontmatter.sh
# and scripts/lint-agent-files.sh. A fix applied to one copy silently left the
# other on the old behaviour, so they live here instead.
#
# Source this file from any script that needs them:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/frontmatter.sh"          # from scripts/
#   source "$(git rev-parse --show-toplevel)/scripts/lib/frontmatter.sh"  # from hooks/
#
# Exports:
#   frontmatter_block <file>        — the lines between the first two `---`
#                                     fences. Prints nothing when line 1 is not
#                                     `---` (no frontmatter block at all).
#   fm_value <block> <key>          — the raw RHS of the first `key:` line in a
#                                     frontmatter block. NOT unquoted, NOT
#                                     trimmed — callers normalise for their own
#                                     schema.
#
# Same convention as scripts/lib/stores.sh: sourced, never executed.

# Extract the frontmatter block (between the first two `---` lines) of a file.
frontmatter_block() {
    awk 'NR==1 && $0!="---"{exit} NR==1{next} /^---$/{exit} {print}' "$1"
}

# Extract a scalar/list `key:` value line from a frontmatter block (raw RHS).
fm_value() {
    # $1 = frontmatter block (multiline string), $2 = key
    printf '%s\n' "$1" | awk -v k="$2" '
        $0 ~ "^"k":" { sub("^"k":[[:space:]]*",""); print; exit }
    '
}
