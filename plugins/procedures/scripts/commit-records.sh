#!/usr/bin/env bash
# commit-records.sh — the deterministic admissibility gate + committer for the
# librarian's write path. The rubric it enforces is specs/RECORD_ADMISSIBILITY.md
# (SSOT); this script does not re-describe it. No model, no network — the whole
# gate is headless bash — no model invocation and no network access.
#
# Per store root the librarian wrote into, ONE call replaces step 6's git block:
#
#   CODEX_ROOT=<root> bash commit-records.sh \
#     --root <root> --paths "<record paths + .index>" \
#     --what "<kinds and counts>" --why "<trigger>" \
#     --source "<session/transcript pointer>" --evidence "<evidence pointer>"
#
# Runs, in order, aborting ATOMICALLY (no commit, no push) on the first failure
# and appending an actionable note (root, failing path(s), which check) to the
# grooming queue (<state-dir>/grooming-queue.md via stores.sh procedures_state_dir):
#   1. pull --rebase (only when an upstream is configured)
#   2. normalize frontmatter of the record paths (idempotent, in place)
#   3. validate — baseline: fence-block, size cap, check-sanitization.sh,
#      check-sections.sh, whole-root duplicate-id scan, case-twin scan,
#      lint-frontmatter.sh
#   4. validate — per-store: <root>/scripts/validate.sh if executable
#   5. build-record-index.sh --root <root> --out <root>/.index
#   6. structured commit (records(<store>): <what> + why/source/evidence trailers)
#   7. push (retry once via pull --rebase; else rebase --abort + queue; never --force)
#
# Test seams:
#   COMMIT_RECORDS_NO_PUSH=1     stop after the commit (step 6), skip push
#   PROCEDURES_STATE_DIR=<dir>   where grooming-queue.md is written
#   LINT_SECTIONS_REQUIRED=1     promote missing-section WARN to a hard block
#   commit-records.sh --normalize --root <root> --paths "..."   normalize only

set -uo pipefail

prog="commit-records"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Uses `declare -A` below — ensure bash 4+ (macOS resolves 3.2). Shim re-execs.
# shellcheck source=scripts/lib/require-bash4.sh
source "$SCRIPT_DIR/lib/require-bash4.sh"
require_bash4 "$0" "$@"
# We are now guaranteed bash 4+. Clear the shim's one-shot re-exec guard so the
# bash4-requiring child scripts we launch via `bash …` (lint-frontmatter.sh,
# build-record-index.sh) can re-exec themselves under bash 4 when the ambient
# `bash` on PATH is macOS 3.2 — the guard is inherited by children and would
# otherwise make their require_bash4 die instead of re-exec.
unset _REQUIRE_BASH4_REEXEC

# shellcheck source=scripts/lib/frontmatter.sh
source "$SCRIPT_DIR/lib/frontmatter.sh"
# shellcheck source=scripts/lib/frontmatter-schema.sh
source "$SCRIPT_DIR/lib/frontmatter-schema.sh"
# stores.sh — only procedures_state_dir / stores_records_dir are used. Its
# source-time discovery runs against CWD and is harmless (result ignored).
# shellcheck source=scripts/lib/stores.sh
source "$SCRIPT_DIR/lib/stores.sh"

SIZE_CAP=32768

usage() {
    cat <<'EOF'
Usage: commit-records.sh --root PATH --paths "p1 p2 .index" \
         --what STR --why STR --source STR --evidence STR
       commit-records.sh --normalize --root PATH --paths "p1 p2"
EOF
}
usage_err() { printf '%s: %s\n' "$prog" "$1" >&2; usage >&2; exit 2; }

# ---- args ----
ROOT="" PATHS_RAW="" WHAT="" WHY="" SOURCE="" EVIDENCE="" NORMALIZE_ONLY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --paths) PATHS_RAW="${2:-}"; shift 2 ;;
        --what) WHAT="${2:-}"; shift 2 ;;
        --why) WHY="${2:-}"; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 ;;
        --normalize) NORMALIZE_ONLY=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_err "unknown arg '$1'" ;;
    esac
done

[ -n "$ROOT" ] || usage_err "--root is required"
[ -d "$ROOT" ] || usage_err "--root '$ROOT' is not a directory"
[ -n "$PATHS_RAW" ] || usage_err "--paths is required"

# Absolute root (paths are root-relative; git -C uses $ROOT).
ROOT="$(cd "$ROOT" && pwd)"
STORE_BASENAME="$(basename "$ROOT")"
RECDIR="$(stores_records_dir "$ROOT")"

# Split --paths into an array (space-separated).
read -ra PATHS <<< "$PATHS_RAW"

# Load the canonical seven-key schema order for normalize. A loader failure
# aborts — normalizing to an empty key order would corrupt every record.
if ! _schema_raw="$(frontmatter_schema_keys)"; then
    printf '%s: cannot load frontmatter schema key order — aborting\n' "$prog" >&2
    exit 1
fi
SCHEMA_KEYS=()
while IFS= read -r _k; do [ -n "$_k" ] && SCHEMA_KEYS+=("$_k"); done <<< "$_schema_raw"
unset _schema_raw _k

# ---- grooming-queue abort helper ----
# _abort <check> <message> — append an actionable note (root, check, message)
# to the grooming queue and exit non-zero. The message names the failing
# path(s) so the librarian can re-invoke with them removed.
_abort() {
    local check="$1" msg="$2" qdir qfile
    qdir="$(procedures_state_dir)"
    qfile="$qdir/grooming-queue.md"
    mkdir -p "$qdir" 2>/dev/null || true
    printf -- '- %s | root: %s | check: %s | %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT" "$check" "$msg" >> "$qfile" 2>/dev/null || true
    printf '%s: BLOCK [%s]: %s\n' "$prog" "$check" "$msg" >&2
    printf '%s: re-invoke this root with the offending path(s) removed once fixed/queued.\n' "$prog" >&2
    exit 1
}

# ---- step 2: normalize ----
# _normalize_file <abs> — canonical frontmatter key order (SCHEMA_KEYS first,
# then any extra keys in original order), links:{} when empty, trailing
# whitespace stripped, trailing newline ensured. Idempotent and in place. A
# file with no leading '---' is left untouched (the fence-block check blocks it).
_normalize_file() {
    local f="$1" first
    [ -f "$f" ] || return 0
    IFS= read -r first < "$f" || true
    [ "$first" = "---" ] || return 0

    local all=() ; mapfile -t all < "$f"
    local n=${#all[@]} i=1 end=-1
    while [ "$i" -lt "$n" ]; do
        [ "${all[$i]}" = "---" ] && { end=$i; break; }
        i=$((i + 1))
    done
    [ "$end" -ge 0 ] || return 0   # unterminated frontmatter — leave for the lint

    local keys=() vals=() j=-1 k=1 line key
    while [ "$k" -lt "$end" ]; do
        line="${all[$k]}"
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
            j=$((j + 1)); key="${line%%:*}"
            keys[$j]="$key"; vals[$j]="$line"
        elif [ "$j" -ge 0 ]; then
            vals[$j]="${vals[$j]}"$'\n'"$line"   # continuation line
        fi
        k=$((k + 1))
    done

    local m rhs
    for ((m = 0; m <= j; m++)); do
        if [ "${keys[$m]}" = "links" ]; then
            rhs="$(printf '%s' "${vals[$m]#links:}" | tr -d '[:space:]')"
            { [ -z "$rhs" ] || [ "$rhs" = "{}" ]; } && vals[$m]="links: {}"
        fi
    done

    local out="" used=() sk
    for ((m = 0; m <= j; m++)); do used[$m]=0; done
    for sk in "${SCHEMA_KEYS[@]}"; do
        for ((m = 0; m <= j; m++)); do
            if [ "${used[$m]}" = "0" ] && [ "${keys[$m]}" = "$sk" ]; then
                out="${out}${vals[$m]}"$'\n'; used[$m]=1
            fi
        done
    done
    for ((m = 0; m <= j; m++)); do
        [ "${used[$m]}" = "0" ] && out="${out}${vals[$m]}"$'\n'
    done

    local body="" b=$((end + 1))
    while [ "$b" -lt "$n" ]; do body="${body}${all[$b]}"$'\n'; b=$((b + 1)); done

    printf '%s' "---"$'\n'"${out}"'---'$'\n'"${body}" \
        | sed 's/[[:space:]]*$//' > "$f.norm.$$"
    mv "$f.norm.$$" "$f"
}

# _slug_of_id <id> — the filename slug: everything after the first '.' (the
# kind prefix), or the whole id when there is no dot.
_slug_of_id() {
    case "$1" in
        *.*) printf '%s' "${1#*.}" ;;
        *)   printf '%s' "$1" ;;
    esac
}

# Normalize every record path; rename the file so its kebab-slug matches id.
# Updates FINAL_PATHS (what gets committed) and REC_PATHS (record .md paths for
# validation) with any post-rename path.
FINAL_PATHS=() REC_PATHS=()
normalize_and_collect() {
    local rel abs newrel newabs id slug base want dir
    for rel in "${PATHS[@]}"; do
        case "$rel" in
            *.md)
                abs="$ROOT/$rel"
                _normalize_file "$abs"
                newrel="$rel"
                if [ -f "$abs" ] && [ "$(head -1 "$abs")" = "---" ]; then
                    id="$(fm_value "$(frontmatter_block "$abs")" id)"; id="${id%%[[:space:]]*}"
                    if [ -n "$id" ]; then
                        slug="$(_slug_of_id "$id")"
                        base="$(basename "$rel")"; dir="$(dirname "$rel")"
                        want="${slug}.md"
                        if [ "$base" != "$want" ]; then
                            [ "$dir" = "." ] && newrel="$want" || newrel="$dir/$want"
                            newabs="$ROOT/$newrel"
                            # Never overwrite an existing DIFFERENT file: two
                            # records that resolve to the same slug (e.g. a
                            # duplicate id) must both survive so the dup-id scan
                            # can block them, not silently merge into one.
                            if [ -e "$newabs" ]; then
                                newrel="$rel"   # keep original name; collision surfaces downstream
                            elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                                git -C "$ROOT" mv -- "$rel" "$newrel" 2>/dev/null || mv "$abs" "$newabs"
                            else
                                mv "$abs" "$newabs"
                            fi
                        fi
                    fi
                fi
                FINAL_PATHS+=("$newrel"); REC_PATHS+=("$newrel")
                ;;
            *)
                FINAL_PATHS+=("$rel")   # .index and any non-record path pass through
                ;;
        esac
    done
}

# ---- normalize-only mode (AC4 evidence) ----
if [ -n "$NORMALIZE_ONLY" ]; then
    normalize_and_collect
    exit 0
fi

normalize_and_collect

# ---- step 1: pull --rebase (only with an upstream) ----
if git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if ! git -C "$ROOT" pull --rebase >/dev/null 2>&1; then
        git -C "$ROOT" rebase --abort >/dev/null 2>&1 || true
        _abort pull "initial 'git pull --rebase' failed for $ROOT; tree left clean"
    fi
fi

# ---- step 3: validate — baseline ----

# (fence-block + size cap, per record path)
for rel in ${REC_PATHS[@]+"${REC_PATHS[@]}"}; do
    abs="$ROOT/$rel"
    [ -f "$abs" ] || _abort fence-block "record path does not exist: $rel"
    if [ "$(head -1 "$abs")" != "---" ]; then
        _abort fence-block "record has no leading '---' frontmatter block: $rel"
    fi
    bytes=$(wc -c < "$abs" | tr -d '[:space:]')
    if [ "$bytes" -gt "$SIZE_CAP" ]; then
        _abort size "record $rel is $bytes bytes, over the $SIZE_CAP-byte cap"
    fi
done

# check-sanitization.sh (leak classes)
if [ "${#REC_PATHS[@]}" -gt 0 ]; then
    SAN_ABS=(); for rel in "${REC_PATHS[@]}"; do SAN_ABS+=("$ROOT/$rel"); done
    if ! san_out="$(bash "$SCRIPT_DIR/check-sanitization.sh" "${SAN_ABS[@]}" 2>&1)"; then
        _abort sanitization "$(printf '%s' "$san_out" | tr '\n' ' ')"
    fi
fi

# check-sections.sh (WARN default; blocks only under LINT_SECTIONS_REQUIRED=1)
if [ "${#REC_PATHS[@]}" -gt 0 ]; then
    SEC_ABS=(); for rel in "${REC_PATHS[@]}"; do SEC_ABS+=("$ROOT/$rel"); done
    if ! sec_out="$(bash "$SCRIPT_DIR/check-sections.sh" "${SEC_ABS[@]}" 2>&1)"; then
        _abort sections "$(printf '%s' "$sec_out" | tr '\n' ' ')"
    fi
    printf '%s\n' "$sec_out" | grep -q . && printf '%s\n' "$sec_out" >&2 || true
fi

# whole-root duplicate-id scan (AFTER the rebase; the entire record tree, not
# just the changed paths — a staged record that collides with one already on
# history would make build-record-index abort fleet-wide on the next pull).
declare -A _ID_FILE=()
_scan_dirs=()
[ -d "$ROOT/$RECDIR" ] && _scan_dirs+=("$ROOT/$RECDIR")
[ -d "$ROOT/plans" ] && _scan_dirs+=("$ROOT/plans")
if [ "${#_scan_dirs[@]}" -gt 0 ]; then
    while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        case "$rf" in */.index/* | */node_modules/* | */templates/*) continue ;; esac
        case "$(basename "$rf")" in INDEX.md | EVOLUTION.md) continue ;; esac
        [ "$(head -1 "$rf" 2>/dev/null)" = "---" ] || continue
        rid="$(fm_value "$(frontmatter_block "$rf")" id)"; rid="${rid%%[[:space:]]*}"
        [ -n "$rid" ] || continue
        if [ -n "${_ID_FILE[$rid]+x}" ]; then
            _abort duplicate-id "duplicate id '$rid' in: ${_ID_FILE[$rid]} ${rf#"$ROOT"/}"
        fi
        _ID_FILE[$rid]="${rf#"$ROOT"/}"
    done < <(find "${_scan_dirs[@]}" -type f -name '*.md' 2>/dev/null | sort)
fi

# case-twin scan — two paths differing only by case, over `git ls-files` plus
# the staged record paths, compared case-insensitively. Catches the twin even
# on a case-insensitive macOS checkout where both map to one on-disk file.
declare -A _LOWER_OF=()
_check_twin() {
    local p="$1" low
    low="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
    if [ -n "${_LOWER_OF[$low]+x}" ] && [ "${_LOWER_OF[$low]}" != "$p" ]; then
        _abort case-twin "case-twin paths (differ only by case): ${_LOWER_OF[$low]} and $p"
    fi
    _LOWER_OF[$low]="$p"
}
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r gp; do [ -n "$gp" ] && _check_twin "$gp"; done \
        < <(git -C "$ROOT" ls-files)
fi
for rel in ${REC_PATHS[@]+"${REC_PATHS[@]}"}; do _check_twin "$rel"; done

# lint-frontmatter.sh — schema keys present, id-unique (whole corpus), links
# resolve, keywords non-empty. Targeted to the record paths.
if [ "${#REC_PATHS[@]}" -gt 0 ]; then
    if ! lint_out="$(LINT_FRONTMATTER_ROOT="$ROOT" bash "$SCRIPT_DIR/lint-frontmatter.sh" "${REC_PATHS[@]}" 2>&1)"; then
        _abort lint-frontmatter "$(printf '%s' "$lint_out" | grep -i 'frontmatter-lint\|duplicate id' | tr '\n' ' ')"
    fi
fi

# ---- step 4: validate — per-store ----
if [ -x "$ROOT/scripts/validate.sh" ]; then
    if ! vs_out="$( cd "$ROOT" && ./scripts/validate.sh ${REC_PATHS[@]+"${REC_PATHS[@]}"} 2>&1 )"; then
        _abort per-store-validate "$(printf '%s' "$vs_out" | tr '\n' ' ')"
    fi
fi

# ---- step 5: rebuild index into the same commit ----
if ! idx_out="$(bash "$SCRIPT_DIR/build-record-index.sh" --root "$ROOT" --out "$ROOT/.index" 2>&1)"; then
    _abort index "build-record-index failed: $(printf '%s' "$idx_out" | tr '\n' ' ')"
fi

# ---- step 6: structured commit ----
git -C "$ROOT" add -- ${FINAL_PATHS[@]+"${FINAL_PATHS[@]}"} 2>/dev/null || \
    _abort commit "git add failed for: ${FINAL_PATHS[*]}"

subject="records(${STORE_BASENAME}): ${WHAT}"
body="$(printf 'why: %s\nsource: %s\nevidence: %s' "$WHY" "$SOURCE" "$EVIDENCE")"
if ! git -C "$ROOT" commit -m "$subject" -m "$body" >/dev/null 2>&1; then
    _abort commit "git commit produced no commit (nothing staged, or hook rejected) for $ROOT"
fi

# ---- step 7: push ----
if [ -n "${COMMIT_RECORDS_NO_PUSH:-}" ]; then
    printf '%s: committed (push skipped: COMMIT_RECORDS_NO_PUSH set)\n' "$prog"
    exit 0
fi
if git -C "$ROOT" remote | grep -q .; then
    if ! git -C "$ROOT" push >/dev/null 2>&1; then
        # rejected — retry once through a rebase
        if ! git -C "$ROOT" pull --rebase >/dev/null 2>&1; then
            git -C "$ROOT" rebase --abort >/dev/null 2>&1 || true
            _abort push "push rejected and 'pull --rebase' could not fast-forward; rebase aborted, tree left clean, no force; files: ${FINAL_PATHS[*]}"
        fi
        if ! git -C "$ROOT" push >/dev/null 2>&1; then
            _abort push "push still rejected after rebase; not forcing; files: ${FINAL_PATHS[*]}"
        fi
    fi
fi

printf '%s: committed and pushed to %s\n' "$prog" "$ROOT"
exit 0
