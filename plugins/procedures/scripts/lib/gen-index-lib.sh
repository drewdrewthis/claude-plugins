#!/usr/bin/env bash
# gen-index-lib.sh — shared logic for scripts/gen-decisions-index.sh and
# scripts/gen-solutions-index.sh. Both scripts source this file and call
# gen_index_render, supplying their own DIR/OUT/banner/header text.
#
# Source this file from any script that needs it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/gen-index-lib.sh"           # from scripts/
#
# Exports:
#   title_for()        — resolve title for a record file: frontmatter
#                         `title:` field > first H1 (stripped) > filename slug
#   gen_index_render()  — collect rows from a directory and render the INDEX.md
#                         table to stdout, given a banner + header markdown block

# ---- frontmatter title: field (non-empty), else empty ----
# Only looks between the first two '---' lines so a `title:` mentioned in
# body prose after frontmatter ends is never matched.
frontmatter_title() {
    awk '
        NR==1 && /^---[[:space:]]*$/ { infm=1; next }
        infm && /^---[[:space:]]*$/ { exit }
        infm && /^title:[[:space:]]*/ {
            sub(/^title:[[:space:]]*/, "")
            print
            exit
        }
    ' "$1" | sed -E 's/^["'"'"'](.*)["'"'"']$/\1/'
}

# ---- first H1 title (strip leading #'s), else empty ----
h1_title() {
    awk '
        /^#[[:space:]]/ { sub(/^#+[[:space:]]*/,""); print; exit }
    ' "$1"
}

# ---- title resolution: frontmatter title: > first H1 > filename slug (base) ----
title_for() {
    local file="$1" base="$2" title
    title="$(frontmatter_title "$file")"
    [ -n "$title" ] && { printf '%s' "$title"; return; }
    title="$(h1_title "$file")"
    [ -n "$title" ] && { printf '%s' "$title"; return; }
    printf '%s' "$base"
}

# ---- collect rows + render the full INDEX.md body to stdout ----
# Args: $1=DIR $2=banner $3=title-line (e.g. "# Decisions index")
#       $4=col2-header (e.g. "Decision") $5=noun (e.g. "decision") $6=script-name (for blurb)
gen_index_render() {
    local dir="$1" banner="$2" h1="$3" col2="$4" noun="$5" script_name="$6"
    local rows="" f base title line

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        base="$(basename "$f" .md)"
        [ "$base" = "INDEX" ] && continue
        title="$(title_for "$f" "$base")"
        printf -v line '%s\t%s' "$base" "$title"
        rows="${rows}${line}"$'\n'
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

    cat <<EOF
<!-- $banner -->

# $h1

One row per $noun record in this directory. GENERATED from the record files themselves — do not hand-edit; rerun \`scripts/$script_name\` after adding/removing a $noun record.

| File | $col2 |
|------|----------|
EOF
    # newest-first: filenames are date-prefixed (YYYY-MM-DD-...), so reverse sort works
    printf '%s' "$rows" | awk 'NF' | sort -t$'\t' -k1,1r | while IFS=$'\t' read -r base title; do
        printf '| [%s](%s.md) | %s |\n' "$base" "$base" "$title"
    done
}
