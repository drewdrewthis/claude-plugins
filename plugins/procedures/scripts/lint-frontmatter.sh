#!/usr/bin/env bash
# lint-frontmatter.sh — frontmatter schema lint for the codex record stores.
#
# Enforces the uniform frontmatter schema — six required keys plus the
# optional `description` — across the record stores discovered by
# scripts/lib/stores.sh (directory-derived; not a fixed count here — see that
# file). See references/principles/file-directory.md "Frontmatter schema" for
# the convention this enforces.
#
# Checks (hard-fail, exit 1 on any violation):
#   (a) PRESENT   — every tracked record .md begins with a `---` frontmatter
#                   block carrying all six required keys: id, kind, date,
#                   keywords, links, status.
#   (b) UNIQUE    — every `id:` is unique across the whole corpus.
#   (c) RESOLVE   — every id referenced under `links:` resolves to a real
#                   record id somewhere in the corpus.
#   (d) NONEMPTY  — `keywords:` is a non-empty list (AC21).
#   (e) PRINCIPLES — `enforced_by:` is OPTIONAL; a principle without it gets
#                    a WARNING (not a hard fail).
#   (f) PROJECT   — `project:` is OPTIONAL; absent is fine (the record is
#                   corpus-wide). PRESENT-but-malformed hard-fails: the value
#                   must be `<repo>` or `<owner>/<repo>` in [a-z0-9._-].
#   (g) DESCRIPTION — `description:` is OPTIONAL for now: ~940 pre-existing
#                     records predate the key, so a missing one is a WARNING,
#                     not a fail. Present-but-empty or spanning more than one
#                     line always hard-fails — a malformed field is a real
#                     defect. LINT_DESCRIPTION_REQUIRED=1 promotes a missing
#                     description to a hard fail (the switch to flip once the
#                     corpus is backfilled).
#
# INDEX.md is excluded (retired in phase 3; frontmatter IS the index).
# A procedure's steps/*.md and templates/*.md are also excluded: they are
# sub-documents chained-to/filled-in by the parent PROCEDURE.md (step files
# carry their own name/description/user-invocable command frontmatter;
# templates carry none at all), not standalone corpus records.
#
# Usage:
#   scripts/lint-frontmatter.sh                 # lint whole corpus
#   scripts/lint-frontmatter.sh <file> [file..] # lint only named files
#                                               # (still resolves links
#                                               #  against the whole corpus)
#
# Targeted mode FAILS CLOSED. A named target that does not exist, or that is
# not a lintable record, is an ERROR — not a silent skip. Every run also prints
# a `linted N file(s)` accounting line (same precedent as
# scripts/lint-procedure-edges.sh and scripts/lint-agent-files.sh), so "it
# printed nothing" can never be mistaken for "it checked something and found
# nothing".
#
# Pure bash/grep/awk; no network, no LLM. Called by git-hooks/pre-commit
# and runnable standalone.

set -uo pipefail

# Repo root = parent of this script's dir. Overridable via
# LINT_FRONTMATTER_ROOT for testing against fixture stores.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This script uses `declare -A` below (associative arrays, bash 4+). Ensure we
# are on such a bash BEFORE any of that runs — macOS ships/resolves bash 3.2.
# shellcheck source=scripts/lib/require-bash4.sh
source "$SCRIPT_DIR/lib/require-bash4.sh"
require_bash4 "$0" "$@"

# PLUGIN ADAPTATION: data root defaults to the host codex (~/.claude), not this
# plugin install dir — upstream these scripts live inside the codex repo itself.
ROOT="${LINT_FRONTMATTER_ROOT:-${CODEX_ROOT:-$HOME/.claude}}"
cd "$ROOT"

# SSOT store list — sourced from scripts/lib/stores.sh (defines STORES array).
# shellcheck source=scripts/lib/stores.sh
source "$SCRIPT_DIR/lib/stores.sh"

# CODEX_STORE_ROOTS — other configured store roots, for the links-RESOLVE
# leniency below only. Deliberately NOT stores.sh's own default (which
# falls back to ${CODEX_ROOT:-$HOME/.claude} independent of
# LINT_FRONTMATTER_ROOT) — re-split with THIS script's own $ROOT as the
# default, so an unset CODEX_STORE_ROOTS always yields an empty OTHER_ROOTS
# here (every existing test sets only LINT_FRONTMATTER_ROOT, never
# CODEX_STORE_ROOTS or CODEX_ROOT — this keeps their behavior unchanged).
# What gets LINTED (corpus_files, is_record_file, TARGETS, id uniqueness)
# stays single-root and untouched: pre-commit runs inside one repo, so
# multi-root has nothing to add there.
_stores_split_roots "${CODEX_STORE_ROOTS:-$ROOT}"
OTHER_ROOTS=()
for _r in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
    _rabs="$(cd "$_r" 2>/dev/null && pwd)" || continue
    [ "$_rabs" = "$ROOT" ] && continue
    OTHER_ROOTS+=("$_rabs")
done
unset _r _rabs

# _id_exists_in_root <root> <id> — best-effort probe: does any record under
# <root> declare this id? Grep-based, not a full frontmatter parse — used
# only to decide whether an unresolved link is plausibly a cross-root
# reference (downgrades an error to a warning); never authoritative, and a
# miss here still leaves the link merely unresolved-noted, not silently
# dropped.
_id_exists_in_root() {
    local root="$1" id="$2"
    grep -RlF -- "id: ${id}" "$root/references" "$root/plans" 2>/dev/null | grep -q .
}

# SSOT frontmatter readers — frontmatter_block() and fm_value(). Shared with
# scripts/lint-agent-files.sh, which used to carry byte-identical copies.
# shellcheck source=scripts/lib/frontmatter.sh
source "$SCRIPT_DIR/lib/frontmatter.sh"
# Required keys are DERIVED from the schema partial, never hardcoded here:
# templates/_frontmatter.partial.md is the SSOT (itself mirroring
# specs/RECORD_FRONTMATTER.md). `description` is excluded from the hard-required
# set — it is governed separately by check (g)/LINT_DESCRIPTION_REQUIRED while
# the corpus backfill is in flight. A loader failure ABORTS: an empty key set
# would turn this linter into a no-op that reports success.
# shellcheck source=scripts/lib/frontmatter-schema.sh
source "$SCRIPT_DIR/lib/frontmatter-schema.sh"
if ! _schema_keys="$(frontmatter_schema_keys --exclude description)"; then
    echo "frontmatter-lint: cannot load required-key schema — aborting" >&2
    exit 1
fi
REQUIRED_KEYS=()
while IFS= read -r _k; do [ -n "$_k" ] && REQUIRED_KEYS+=("$_k"); done <<< "$_schema_keys"
unset _schema_keys _k
if [ ${#REQUIRED_KEYS[@]} -eq 0 ]; then
    echo "frontmatter-lint: schema yielded zero required keys — aborting" >&2
    exit 1
fi
# `project:` is OPTIONAL — absent means the record is corpus-wide. A malformed
# value is worse than an absent one: it looks scoped to a repo and matches
# nothing.
PROJECT_RE='^[a-z0-9._-]+(/[a-z0-9._-]+)?$'

# ---- collect the full corpus (for id uniqueness + link resolution) ----
# Excludes INDEX.md everywhere and archived plan records (_archived*) — those
# are not active, linted records.
corpus_files() {
    local d
    for d in "${STORES[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -type f -name '*.md' ! -name 'INDEX.md' ! -path '*_archived*' ! -path '*/node_modules/*' ! -path '*/steps/*' ! -path '*/templates/*'
    done | sort
}

# True for a lintable record: <store>/**/*.md, not INDEX.md, not archived, not
# vendored. This is the PREDICATE form of the corpus_files() filters above —
# the two must agree, or targeted mode lints something the whole-corpus run
# does not (or refuses something it does).
is_record_file() {
    local f="$1" s in_store=0
    for s in "${STORES[@]}"; do
        case "$f" in "${s}/"*.md) in_store=1; break ;; esac
    done
    [ "$in_store" -eq 1 ] || return 1
    [ "$(basename "$f")" = "INDEX.md" ] && return 1
    case "$f" in
        *_archived*|*/node_modules/*|*/steps/*|*/templates/*) return 1 ;;
    esac
    return 0
}

# A HAND-EDITED sub-document under a store: a real file someone stages and commits,
# which the corpus scan deliberately excludes from record linting. Distinct from a
# path that is simply not a record (typo, renamed file) — that still errors. Also
# distinct from INDEX.md, which is GENERATED: naming it as a target is a caller bug
# and stays an error (tested).
#
# Conflating the two made every staged `steps/*.md` edit uncommittable without
# --no-verify, because pre-commit passes staged paths as named targets.
is_editable_subdocument() {
    local f="$1" s in_store=0
    for s in "${STORES[@]}"; do
        case "$f" in "${s}/"*.md) in_store=1; break ;; esac
    done
    [ "$in_store" -eq 1 ] || return 1
    [ "$(basename "$f")" = "INDEX.md" ] && return 1
    case "$f" in
        *_archived*|*/steps/*|*/templates/*) return 0 ;;
    esac
    return 1
}

# frontmatter_block() and fm_value() come from scripts/lib/frontmatter.sh
# (sourced above).

# ---- build corpus id map: id -> file (for uniqueness + resolution) ----
declare -A ID_OF_FILE=()
declare -A FILE_OF_ID=()
declare -A DUP_IDS=()
ALL_IDS=""

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(head -1 "$f")" != "---" ]; then
        continue   # missing-frontmatter caught in the per-file pass below
    fi
    block="$(frontmatter_block "$f")"
    id="$(fm_value "$block" id)"
    id="${id%%[[:space:]]*}"   # trim trailing ws/comment
    [ -n "$id" ] || continue
    ID_OF_FILE["$f"]="$id"
    if [ -n "${FILE_OF_ID[$id]+x}" ]; then
        DUP_IDS["$id"]="${FILE_OF_ID[$id]} ${f}"
    else
        FILE_OF_ID["$id"]="$f"
    fi
    ALL_IDS="${ALL_IDS}${id}"$'\n'
done < <(corpus_files)

# ---- decide which files to actually lint ----
# TARGETED=1 means every path came from the CALLER and is therefore a claim
# that the path is a lintable record. A claim that turns out to be false is an
# error. In whole-corpus mode the paths come from corpus_files(), which cannot
# produce one, so the same check is unreachable there.
if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
    TARGETED=1
else
    mapfile -t TARGETS < <(corpus_files)
    TARGETED=0
fi

FAIL=0
# How many files the per-file pass actually inspected (the accounting line).
LINTED=0
# How many linted files have no description: key — printed as a summary line
# every run so the backfill has a number to chase (flip
# LINT_DESCRIPTION_REQUIRED=1 once this reaches 0).
MISSING_DESCRIPTION=0
err() { echo "❌ frontmatter-lint: $*" >&2; FAIL=1; }
warn() { echo "⚠ frontmatter-lint WARNING: $*" >&2; }

for f in "${TARGETS[@]:-}"; do
    [ -n "$f" ] || continue

    # FAIL CLOSED on a named target we cannot lint. These were `|| continue`
    # — silent skips with nothing counting what got linted, so
    # `lint-frontmatter.sh references/decisions/typo.md` printed nothing and
    # exited 0. A typo'd path, a renamed file, or a caller word-splitting a
    # filename that contains a space all read as "checked, clean".
    if ! is_record_file "$f"; then
        if [ "$TARGETED" = "1" ] && ! is_editable_subdocument "$f"; then
            err "$f: not a lintable record (expected <store>/**/*.md under one of: ${STORES_ALT//|/, }; not INDEX.md, not _archived)"
        fi
        continue
    fi
    if [ ! -f "$f" ]; then
        if [ "$TARGETED" = "1" ]; then
            err "$f: named target does not exist"
        fi
        continue
    fi

    # Check for command frontmatter before counting this file as linted. Files
    # with `user-invocable:` are not records and must be skipped entirely.
    # Check only the frontmatter block (between the two `---` lines), not the
    # whole file body.
    if [ "$(head -1 "$f")" = "---" ]; then
        block="$(frontmatter_block "$f")"
        fm_haystack_check=$'\n'"$block"$'\n'
        case "$fm_haystack_check" in
            *$'\n'"user-invocable:"*) continue ;;
        esac
    fi

    LINTED=$((LINTED + 1))

    # (a) PRESENT — first line must be the frontmatter fence.
    if [ "$(head -1 "$f")" != "---" ]; then
        err "$f: missing frontmatter block (first line is not '---')"
        continue
    fi
    block="$(frontmatter_block "$f")"

    # Zero-fork, pipe-free membership haystack. `printf '%s\n' "$block" | grep -q`
    # looks equivalent and is not: grep exits on its first match, the still-
    # writing printf takes SIGPIPE, and `set -o pipefail` reports 141 for a
    # SUCCESSFUL match once the block outgrows the pipe buffer. Every present
    # key then reads as missing (#46, hooks/tests/frontmatter-sigpipe.bats).
    # The leading newline lets a key on the block's FIRST line match too.
    fm_haystack=$'\n'"$block"$'\n'

    # all six required keys present
    for key in "${REQUIRED_KEYS[@]}"; do
        # "${key}:" is quoted inside the pattern, so it is matched literally.
        case "$fm_haystack" in
            *$'\n'"${key}:"*) ;;
            *) err "$f: frontmatter missing required key '${key}:'" ;;
        esac
    done

    # (d) NONEMPTY keywords — reject `keywords:` with empty `[]` or nothing.
    kw="$(fm_value "$block" keywords)"
    kw_trim="$(printf '%s' "$kw" | tr -d '[:space:]')"
    if [ -z "$kw_trim" ] || [ "$kw_trim" = "[]" ]; then
        err "$f: keywords: list is empty (AC21 requires at least one keyword)"
    fi

    # (e) PRINCIPLES — `enforced_by:` is OPTIONAL. A principle without it is
    # aspirational prose; emit a WARNING (never FAIL) so the gap is visible.
    case "$f" in
        references/principles/*.md)
            # Same SIGPIPE hazard as the required-key loop above (#46).
            case "$fm_haystack" in
                *$'\n'"enforced_by:"*) ;;
                *) warn "$f: principle has no 'enforced_by:' — aspirational (not enforced)" ;;
            esac
            ;;
    esac

    # (f) PROJECT — OPTIONAL key, shape-checked only when present.
    # Normalised before comparing (truncate at the first whitespace, then
    # strip one outer quote pair, in that order): a quoted scalar must lint
    # clean against PROJECT_RE, not fail on its quotes.
    # Same haystack/case idiom as the required-key loop above, and for the same
    # SIGPIPE reason (#46) — never `printf | grep -q`.
    case "$fm_haystack" in
        *$'\n'"project:"*)
            proj="$(fm_value "$block" project)"
            proj="${proj%%[[:space:]]*}"
            case "$proj" in
                \"*\") proj="${proj#\"}"; proj="${proj%\"}" ;;
                \'*\') proj="${proj#\'}"; proj="${proj%\'}" ;;
            esac
            # PROJECT_RE unquoted: bash 3.2 (macOS) treats a quoted =~ operand
            # as a literal string, which would match nothing.
            if ! [[ "$proj" =~ $PROJECT_RE ]]; then
                err "$f: project: '${proj}' is malformed — expected <repo> or <owner>/<repo>, characters [a-z0-9._-] (omit the key entirely for a corpus-wide record)"
            fi
            ;;
    esac

    # (g) DESCRIPTION — OPTIONAL key (for now): retrieval match surface, one
    # line of prose. Missing is a WARNING unless LINT_DESCRIPTION_REQUIRED=1
    # (the switch to flip once the corpus is backfilled — ~940 records
    # predate this key). Present-but-malformed always hard-fails: empty, or
    # spanning more than one line (a YAML block scalar or a wrapped
    # continuation) — a broken field is worse than an absent one. Herestring,
    # not a pipe, feeds awk: awk's `exit` can leave an upstream pipe writer
    # SIGPIPE'd, and `set -o pipefail` would then misreport this as failure
    # (#46, same hazard the required-key haystack above avoids).
    case "$fm_haystack" in
        *$'\n'"description:"*)
            desc_lines="$(awk '
                /^description:/ { capture=1; n++; next }
                capture && /^[A-Za-z_][A-Za-z0-9_]*:/ { exit }
                capture { n++ }
                END { print n+0 }
            ' <<< "$block")"
            if [ "$desc_lines" -gt 1 ]; then
                err "$f: description: spans multiple lines — must be single-line prose"
            else
                desc_val="$(fm_value "$block" description)"
                desc_val_trim="$(printf '%s' "$desc_val" | tr -d '[:space:]')"
                if [ -z "$desc_val_trim" ]; then
                    err "$f: description: is present but empty"
                fi
            fi
            ;;
        *)
            MISSING_DESCRIPTION=$((MISSING_DESCRIPTION + 1))
            if [ "${LINT_DESCRIPTION_REQUIRED:-0}" = "1" ]; then
                err "$f: frontmatter missing required key 'description:' (LINT_DESCRIPTION_REQUIRED=1)"
            else
                warn "$f: frontmatter missing 'description:' (not yet required — set LINT_DESCRIPTION_REQUIRED=1 to enforce after backfill)"
            fi
            ;;
    esac

    # links: targets must resolve. Accept either inline-map form
    #   links: { procedures: [a, b], failure-modes: [c] }
    # or omitted/empty. Extract every bare id-looking token inside the value.
    links_val="$(fm_value "$block" links)"
    # strip braces/brackets, the sub-key names, and commas — leaving a
    # whitespace-separated list of referenced ids (empty for `{}`).
    # STORES_BASENAME_ALT (from stores.sh) strips the sub-key names in links values.
    ids="$(printf '%s' "$links_val" \
        | tr -d '{}[]' \
        | sed -E "s/(${STORES_BASENAME_ALT}):/ /g" \
        | tr ',' ' ')"
    for lid in $ids; do
        lid="${lid//\"/}"
        lid="${lid//\'/}"
        [ -n "$lid" ] || continue
        [ "$lid" = "~" ] && continue
        if [ -z "${FILE_OF_ID[$lid]+x}" ]; then
            resolved_elsewhere=0
            for _or in ${OTHER_ROOTS[@]+"${OTHER_ROOTS[@]}"}; do
                if _id_exists_in_root "$_or" "$lid"; then resolved_elsewhere=1; break; fi
            done
            if [ "$resolved_elsewhere" -eq 1 ]; then
                :   # resolves in another configured root -- not an error
            elif [ "${#OTHER_ROOTS[@]}" -gt 0 ]; then
                warn "$f: links target '$lid' resolves to no record id in any configured root (grooming-queue material -- verify or fix)"
            else
                err "$f: links target '$lid' resolves to no record id in the corpus"
            fi
        fi
    done
done

# The accounting line — printed on EVERY run, pass or fail, so silence is never
# mistakable for a clean bill of health. Precedent: scripts/lint-procedure-edges.sh
# prints `corpus=N nodes, edges_checked=N` unconditionally.
echo "frontmatter-lint: linted $LINTED file(s)"
echo "frontmatter-lint: $MISSING_DESCRIPTION file(s) missing description"

# (b) UNIQUE — report duplicate ids (only meaningful on a full-corpus run,
# but a targeted run still benefits from the corpus-wide map).
for dup in "${!DUP_IDS[@]}"; do
    err "duplicate id '$dup' in: ${DUP_IDS[$dup]}"
done

if [ "$FAIL" -ne 0 ]; then
    echo "" >&2
    echo "frontmatter-lint failed. Fix the records above, or (NOT recommended)" >&2
    echo "bypass with: git commit --no-verify" >&2
    exit 1
fi
exit 0
