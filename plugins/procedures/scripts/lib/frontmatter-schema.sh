#!/usr/bin/env bash
# frontmatter-schema.sh — SSOT loader for the record-frontmatter required-key
# list. Parses key names out of the canonical schema partial
# (skills/update-records/templates/_frontmatter.partial.md), which mirrors
# specs/RECORD_FRONTMATTER.md, instead of letting a caller hardcode a
# REQUIRED_KEYS array that can drift from either. Sourced, never executed —
# same convention as lib/stores.sh and lib/frontmatter.sh.
#
# Source this file from any script that needs it:
#   source "$SCRIPT_DIR/lib/frontmatter-schema.sh"   # from scripts/
#
# Exports:
#   frontmatter_schema_keys [--exclude KEY]
#       Prints one key name per line, in the partial's frontmatter order.
#       --exclude KEY omits one key from the printed list (e.g. `description`,
#       which lint-frontmatter.sh gates separately via LINT_DESCRIPTION_REQUIRED
#       rather than folding into its hard-required loop).
#
#       Hard-fails — stderr message, return 1, NOTHING on stdout — if the
#       partial is missing, has no closed `---`-fenced block, or the fence
#       yields zero keys. NEVER silently returns an empty set: a caller that
#       mishandles the return code and iterates stdout anyway gets zero
#       lines, which reads as "did nothing" (a `for key in "${arr[@]}"` over
#       an empty array is a visible no-op check), not as a quiet "schema is
#       empty" that passes every record. Caller contract — capture via
#       command substitution (which propagates the function's exit status),
#       never `mapfile ... < <(frontmatter_schema_keys)` (process
#       substitution swallows the function's failure and mapfile still
#       "succeeds" reading zero lines):
#           if ! keys="$(frontmatter_schema_keys --exclude description)"; then
#               echo "cannot load schema" >&2; exit 1
#           fi
#           REQUIRED_KEYS=()
#           while IFS= read -r k; do [ -n "$k" ] && REQUIRED_KEYS+=("$k"); done <<< "$keys"
#
# Override FRONTMATTER_SCHEMA_PARTIAL to point at a fixture for testing (same
# pattern as lint-frontmatter.sh's LINT_FRONTMATTER_ROOT override).

_fs_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTMATTER_SCHEMA_PARTIAL="${FRONTMATTER_SCHEMA_PARTIAL:-$_fs_lib_dir/../../skills/update-records/templates/_frontmatter.partial.md}"
unset _fs_lib_dir

frontmatter_schema_keys() {
    local exclude="" partial="$FRONTMATTER_SCHEMA_PARTIAL"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --exclude) exclude="${2:-}"; shift 2 ;;
            *) echo "frontmatter-schema: frontmatter_schema_keys: unknown arg '$1'" >&2; return 1 ;;
        esac
    done

    if [ ! -f "$partial" ]; then
        echo "frontmatter-schema: partial not found at $partial — cannot derive required keys" >&2
        return 1
    fi

    # Fence count first, as its own check: distinguishes "no frontmatter
    # block at all" / "unclosed fence" from "fence present, zero keys in it"
    # — two different defects, two different messages. Not part of a pipe,
    # so grep's no-match exit status (1) is never seen by `set -o pipefail`.
    local fence_count
    fence_count="$(grep -c '^---$' "$partial")"
    if [ "$fence_count" -lt 2 ]; then
        echo "frontmatter-schema: $partial has no closed '---' frontmatter fence (found $fence_count '---' line(s)) — cannot derive required keys" >&2
        return 1
    fi

    local keys
    keys="$(awk -v excl="$exclude" '
        /^---$/ { fence++; if (fence==1) next; if (fence==2) exit }
        fence==1 && /^[A-Za-z_][A-Za-z0-9_]*:/ {
            k=$0; sub(/:.*/, "", k)
            if (k != excl) print k
        }
    ' "$partial")"

    if [ -z "$keys" ]; then
        echo "frontmatter-schema: $partial's frontmatter fence yielded zero keys — cannot derive required keys" >&2
        return 1
    fi

    printf '%s\n' "$keys"
}
