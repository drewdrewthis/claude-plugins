#!/usr/bin/env bash
# PLUGIN ADAPTATION: no upstream counterpart — new librarian commit-gate machinery.
# commit-records.sh — the deterministic admissibility gate + committer for the
# librarian's write path. The rubric it enforces is specs/RECORD_ADMISSIBILITY.md
# (SSOT); this script does not re-describe it. No model, no network — the whole
# gate is headless bash — no model invocation and no network access.
#
# Per store root the librarian wrote into, ONE call replaces step 6's git block:
#
#   CODEX_ROOT=<root> bash commit-records.sh \
#     --root <root> --paths "<record .md paths>" --what "<kinds and counts>" \
#     --why-file <dir>/why.txt --source-file <dir>/source.txt \
#     --evidence-file <dir>/evidence.txt
#
# The metadata fields also accept inline forms (--why/--source/--evidence);
# prefer the -file forms for transcript-derived text — nothing is ever
# assembled into shell source, so there is no quoting or escaping to get wrong.
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

# usage — print the supported invocation forms to stdout. Prefer the -file
# forms (--why-file/--source-file/--evidence-file) for transcript-derived
# text; nothing is ever assembled into shell source.
usage() {
    cat <<'EOF'
Usage: commit-records.sh --root PATH --paths "p1.md p2.md" \
         --what STR --why STR --source STR --evidence STR
       commit-records.sh --root PATH --paths "p1.md p2.md" --what STR \
         --why-file PATH --source-file PATH --evidence-file PATH
       commit-records.sh --normalize --root PATH --paths "p1.md p2.md"

Prefer the -file forms for transcript-derived text; nothing is ever
assembled into shell source.
EOF
}
# usage_err — print "prog: msg" plus the usage text to stderr, then exit 2.
usage_err() { printf '%s: %s\n' "$prog" "$1" >&2; usage >&2; exit 2; }

# ---- args ----
ROOT="" PATHS_RAW="" WHAT="" WHY="" SOURCE="" EVIDENCE="" NORMALIZE_ONLY=""
# Per-field origin flags: distinguish an inline form from a -file form so the
# two cannot be supplied for the same field (the -file form reads the whole
# file into the same variable, so nothing is ever assembled into shell source).
WHY_INLINE="" WHY_FILE="" SOURCE_INLINE="" SOURCE_FILE="" EVIDENCE_INLINE="" EVIDENCE_FILE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        # Value-taking options: reject a trailing option with no value. Without
        # this, `shift 2` on a single remaining arg fails (errexit is off), $#
        # never decreases, and the parser loops forever.
        --root | --paths | --what | --why | --source | --evidence \
            | --why-file | --source-file | --evidence-file)
            [ "$#" -ge 2 ] || usage_err "option '$1' requires a value"
            case "$1" in
                --root) ROOT="$2" ;;
                --paths) PATHS_RAW="$2" ;;
                --what) WHAT="$2" ;;
                --why) WHY="$2"; WHY_INLINE=1 ;;
                --source) SOURCE="$2"; SOURCE_INLINE=1 ;;
                --evidence) EVIDENCE="$2"; EVIDENCE_INLINE=1 ;;
                # -file forms: read the file's full content verbatim into the
                # field. Missing/unreadable file is a usage error.
                --why-file)
                    [ -r "$2" ] || usage_err "--why-file: cannot read: $2"
                    WHY="$(cat -- "$2")"; WHY_FILE=1 ;;
                --source-file)
                    [ -r "$2" ] || usage_err "--source-file: cannot read: $2"
                    SOURCE="$(cat -- "$2")"; SOURCE_FILE=1 ;;
                --evidence-file)
                    [ -r "$2" ] || usage_err "--evidence-file: cannot read: $2"
                    EVIDENCE="$(cat -- "$2")"; EVIDENCE_FILE=1 ;;
            esac
            shift 2 ;;
        --normalize) NORMALIZE_ONLY=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_err "unknown arg '$1'" ;;
    esac
done

# The inline and -file forms of a field are mutually exclusive: supplying both
# is ambiguous about which text should land in the commit body.
[ -n "$WHY_INLINE" ] && [ -n "$WHY_FILE" ] \
    && usage_err "--why and --why-file are mutually exclusive"
[ -n "$SOURCE_INLINE" ] && [ -n "$SOURCE_FILE" ] \
    && usage_err "--source and --source-file are mutually exclusive"
[ -n "$EVIDENCE_INLINE" ] && [ -n "$EVIDENCE_FILE" ] \
    && usage_err "--evidence and --evidence-file are mutually exclusive"

[ -n "$ROOT" ] || usage_err "--root is required"
[ -d "$ROOT" ] || usage_err "--root '$ROOT' is not a directory"
[ -n "$PATHS_RAW" ] || usage_err "--paths is required"

# Absolute root (paths are root-relative; git -C uses $ROOT).
ROOT="$(cd "$ROOT" && pwd)"
STORE_BASENAME="$(basename "$ROOT")"
RECDIR="$(stores_records_dir "$ROOT")"

# Split --paths into an array (space-separated).
read -ra PATHS <<< "$PATHS_RAW"

# Containment + kind filter: every --paths entry is a root-relative record .md
# file. Reject absolute paths and any `..` segment so a caller cannot make the
# gate normalize, rename, or stage a file outside the selected store
# (symlinked-parent escapes are additionally rejected per-file below, after the
# parent dir is physically resolved). Reject any non-.md entry so a sensitive
# non-record file cannot ride in unvalidated — EXCEPT the literal `.index`,
# accepted for caller compatibility and silently dropped, since the gate adds
# `.index` itself (step 5).
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
_FILTERED=()
for _p in ${PATHS[@]+"${PATHS[@]}"}; do
    case "$_p" in
        /*) usage_err "--paths entry must be root-relative, not absolute: $_p" ;;
        .. | ../* | */.. | */../*) usage_err "--paths entry escapes --root via '..': $_p" ;;
        .index) continue ;;
        *.md) _FILTERED+=("$_p") ;;
        *) usage_err "--paths entry is not a record .md file: $_p" ;;
    esac
done
unset _p
[ "${#_FILTERED[@]}" -gt 0 ] || usage_err "--paths has no record .md entries"
PATHS=("${_FILTERED[@]}")
unset _FILTERED

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
    # The grooming queue is the durable record that this root was blocked; a
    # silent write failure would let the caller assume the block was queued when
    # it was not. Surface a distinct queue-write error instead of swallowing it.
    if ! mkdir -p "$qdir" 2>/dev/null \
        || ! printf -- '- %s | root: %s | check: %s | %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT" "$check" "$msg" >> "$qfile" 2>/dev/null; then
        printf '%s: QUEUE-WRITE-FAILED: could not record this block in %s\n' "$prog" "$qfile" >&2
    fi
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

# normalize_and_collect — normalize every record path; rename the file so its
# kebab-slug matches id. Updates FINAL_PATHS (what gets committed) and REC_PATHS
# (record .md paths for validation) with any post-rename path.
FINAL_PATHS=() REC_PATHS=()
normalize_and_collect() {
    local rel abs newrel newabs id slug base want dir
    for rel in "${PATHS[@]}"; do
        case "$rel" in
            *.md)
                abs="$ROOT/$rel"
                # Refuse a symlinked record: following it would let a caller
                # normalize/stage a file whose real location is anywhere on disk.
                [ -L "$abs" ] \
                    && _abort path "record path is a symlink (refusing to follow): $rel"
                # Symlinked-parent escape guard: the physical parent dir must
                # stay under the physical root before we write/rename the file.
                pdir="$(cd "$ROOT/$(dirname "$rel")" 2>/dev/null && pwd -P)" \
                    || _abort path "cannot resolve parent directory of: $rel"
                case "$pdir/" in
                    "$ROOT_PHYS"/*) : ;;
                    *) _abort path "record path escapes --root (symlink?): $rel" ;;
                esac
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
                # PATHS is pre-filtered to record .md only (.index dropped, any
                # other non-.md rejected as a usage error), so this is unreachable.
                _abort path "non-record path reached normalize: $rel"
                ;;
        esac
    done
}

# _dup_id_scan — whole-root duplicate-id scan over the record tree (records dir
# + plans/), skipping index/vendor/template dirs and INDEX/EVOLUTION files. Two
# records sharing an id abort. Reused on the push-retry path after a rebase.
_dup_id_scan() {
    local -A _ID_FILE=()
    local _scan_dirs=() rf rid
    [ -d "$ROOT/$RECDIR" ] && _scan_dirs+=("$ROOT/$RECDIR")
    [ -d "$ROOT/plans" ] && _scan_dirs+=("$ROOT/plans")
    [ "${#_scan_dirs[@]}" -gt 0 ] || return 0
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
}

# _rebuild_index — regenerate <root>/.index so it lands in the same commit as
# the records it describes. Reused on the push-retry path after a rebase, where
# the committed index would otherwise describe the pre-rebase tree.
_rebuild_index() {
    local idx_out
    if ! idx_out="$(bash "$SCRIPT_DIR/build-record-index.sh" --root "$ROOT" --out "$ROOT/.index" 2>&1)"; then
        _abort index "build-record-index failed: $(printf '%s' "$idx_out" | tr '\n' ' ')"
    fi
}

# ---- normalize-only mode (AC4 evidence) ----
if [ -n "$NORMALIZE_ONLY" ]; then
    normalize_and_collect
    exit 0
fi

# ---- step 1: pull --rebase (only with an upstream) ----
# Runs BEFORE normalize: normalization rewrites and `git mv`s tracked records,
# and `git pull --rebase` refuses a dirty worktree/index. Sync first, then
# normalize the local records against current upstream.
if git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if ! git -C "$ROOT" pull --rebase >/dev/null 2>&1; then
        git -C "$ROOT" rebase --abort >/dev/null 2>&1 || true
        _abort pull "initial 'git pull --rebase' failed for $ROOT; tree left clean"
    fi
fi

# ---- step 2: normalize ----
normalize_and_collect

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
_dup_id_scan

# case-twin scan — two paths differing only by case, over `git ls-files` plus
# the staged record paths, compared case-insensitively. Catches the twin even
# on a case-insensitive macOS checkout where both map to one on-disk file.
declare -A _LOWER_OF=()
# _check_twin <path> — record <path> under its lowercased key; abort if a
# different path already claimed that key (i.e. a case-twin was seen).
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
_rebuild_index
# The gate — not the caller — stages the rebuilt index. FINAL_PATHS holds only
# record .md paths (any caller-supplied .index was dropped up front); append it
# now so the `git add` below stages the index alongside the records it describes.
FINAL_PATHS+=(".index")

# ---- step 6: structured commit ----
# Constrain the transcript-derived commit metadata (what/why/source/evidence)
# before it lands verbatim in the commit body. The baseline sanitization scans
# record FILES only; these fields bypass it entirely. They are meant to be
# bounded pointers (session id, line ranges), so cap their length and run them
# through the same leak-class check — a personal path, token, or key must not
# ride into git history via a commit trailer.
META_CAP=2048
for _mv in "$WHAT" "$WHY" "$SOURCE" "$EVIDENCE"; do
    # Byte count (not character count): the cap is a byte budget, and ${#_mv}
    # counts characters, which under a UTF-8 locale undercounts a multi-byte
    # field. LC_ALL=C wc -c counts raw bytes.
    _mb=$(printf '%s' "$_mv" | LC_ALL=C wc -c | tr -d '[:space:]')
    if [ "$_mb" -gt "$META_CAP" ]; then
        _abort metadata "commit metadata field exceeds the ${META_CAP}-byte pointer cap"
    fi
done
unset _mv _mb
_meta_tmp="$(mktemp)"
printf '%s\n%s\n%s\n%s\n' "$WHAT" "$WHY" "$SOURCE" "$EVIDENCE" > "$_meta_tmp"
if ! _meta_out="$(bash "$SCRIPT_DIR/check-sanitization.sh" "$_meta_tmp" 2>&1)"; then
    rm -f "$_meta_tmp"
    _abort metadata "commit metadata leaks unsafe content: $(printf '%s' "$_meta_out" | tr '\n' ' ')"
fi
rm -f "$_meta_tmp"

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
        # The rebase merged upstream records into the tree. Re-run the two checks
        # that the merged tree can invalidate: the fleet-safety duplicate-id scan
        # (a merged record may now collide) and the index rebuild (the committed
        # .index describes the pre-rebase tree). Commit any refreshed index as a
        # new commit before retrying — never --amend, never --force.
        _dup_id_scan
        _rebuild_index
        git -C "$ROOT" add -- .index 2>/dev/null || true
        if ! git -C "$ROOT" diff --cached --quiet -- .index 2>/dev/null; then
            if ! git -C "$ROOT" commit \
                -m "records(${STORE_BASENAME}): reindex after push-retry rebase" \
                -m "$(printf 'why: refresh .index against upstream merged during push retry\nsource: %s\nevidence: %s' "$SOURCE" "$EVIDENCE")" \
                >/dev/null 2>&1; then
                _abort push "reindex commit failed after rebase; tree left as-is; files: ${FINAL_PATHS[*]}"
            fi
        fi
        if ! git -C "$ROOT" push >/dev/null 2>&1; then
            _abort push "push still rejected after rebase; not forcing; files: ${FINAL_PATHS[*]}"
        fi
    fi
fi

printf '%s: committed and pushed to %s\n' "$prog" "$ROOT"
exit 0
