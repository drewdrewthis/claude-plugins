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
#     --root <root> --paths "<record .md paths> [mistakes.jsonl]" --what "<kinds and counts>" \
#     --why-file <dir>/why.txt --source-file <dir>/source.txt \
#     --evidence-file <dir>/evidence.txt
#
# The metadata fields also accept inline forms (--why/--source/--evidence);
# prefer the -file forms for transcript-derived text — nothing is ever
# assembled into shell source, so there is no quoting or escaping to get wrong.
# A -file path must live under the procedures state dir (the same dir as the
# librarian's cursors and grooming queue, `$(procedures_state_dir)`), typically
# <state-dir>/tmp/commit-<root-slug>/; a path outside it is refused.
#
# The root-relative `mistakes.jsonl` (log-record.sh's append-only mistake log)
# is the one non-.md path accepted, so a wake's mistake appends commit with its
# records instead of sitting uncommitted. It skips the record-only checks
# (normalize, fence/size, sections, lint); step 6 vets only the rows the commit
# ADDS, from the staged blob, with check-sanitization.sh --strict, and moves a
# leaking row to <state-dir>/mistakes.quarantine.jsonl instead of blocking.
# `--release-quarantine <root>` appends that root's quarantined rows back to its
# mistakes.jsonl, for the owner to edit and re-run once reviewed.
#
# Runs, in order, aborting ATOMICALLY (no commit, no push) on the first failure
# and appending an actionable note (root, failing path(s), which check) to the
# grooming queue (<state-dir>/grooming-queue.md via stores.sh procedures_state_dir):
#   0. set `mistakes.jsonl merge=union` in this clone's info/attributes
#   1. pull --rebase (only when an upstream is configured)
#   2. normalize frontmatter of the record paths (idempotent, in place)
#   3. validate — baseline: fence-block, size cap, check-sanitization.sh,
#      check-sections.sh, whole-root duplicate-id scan, case-twin scan,
#      lint-frontmatter.sh
#   4. validate — per-store: <root>/scripts/validate.sh if executable
#   5. build-record-index.sh --root <root> --out <root>/.index
#   6. stage + vet mistakes.jsonl (when given), then structured commit
#      (records(<store>): <what> + why/source/evidence trailers)
#   7. push (retry once via pull --rebase; else rebase --abort + queue; never --force)
#
# Test seams:
#   COMMIT_RECORDS_NO_PUSH=1     stop after the commit (step 6), skip push
#   PROCEDURES_STATE_DIR=<dir>   where grooming-queue.md is written
#   LINT_SECTIONS_REQUIRED=1     promote missing-section WARN to a hard block
#   commit-records.sh --normalize --root <root> --paths "..."   normalize only
#   MISTAKES_NO_FLOCK=1 / MISTAKES_LOCK_WAIT_SECS  see scripts/lib/mistakes-lock.sh

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
# shellcheck source=scripts/lib/mistakes-lock.sh
source "$SCRIPT_DIR/lib/mistakes-lock.sh"

SIZE_CAP=32768
JSONL_QUARANTINE="$(procedures_state_dir)/mistakes.quarantine.jsonl"
JSONL_QUARANTINE_LOCK="${JSONL_QUARANTINE%.jsonl}.lock"

# usage — print the supported invocation forms to stdout. Prefer the -file
# forms (--why-file/--source-file/--evidence-file) for transcript-derived
# text; nothing is ever assembled into shell source. A -file path must live
# under the procedures state dir (`$(procedures_state_dir)`).
usage() {
    cat <<'EOF'
Usage: commit-records.sh --root PATH --paths "p1.md p2.md [mistakes.jsonl]" \
         --what STR --why STR --source STR --evidence STR
       commit-records.sh --root PATH --paths "p1.md p2.md [mistakes.jsonl]" --what STR \
         --why-file PATH --source-file PATH --evidence-file PATH
       commit-records.sh --normalize --root PATH --paths "p1.md p2.md"
       commit-records.sh --release-quarantine PATH

Prefer the -file forms for transcript-derived text; nothing is ever
assembled into shell source. A -file path must live under the procedures
state dir, typically <state-dir>/tmp/commit-<root-slug>/. The
root-relative mistakes.jsonl is the one non-.md path --paths accepts.
EOF
}
# _read_meta_file FILE OPT — read a metadata file verbatim into _META_VALUE
# (trailing newlines preserved, no command-substitution trimming). FILE must be
# a readable regular file whose physical parent dir is under the procedures
# state dir (`$(procedures_state_dir)`, typically <state-dir>/tmp/commit-<root-slug>/)
# and must not be a symlink — so a caller cannot make the gate read, then commit
# verbatim, a file anywhere on disk. Any failure is a usage error naming OPT.
_read_meta_file() {
    local _sd _sdp _fdp
    [ -L "$1" ] && usage_err "$2: refusing a symlink: $1"
    _sd="$(procedures_state_dir)"
    [ -d "$_sd" ] || usage_err "$2: procedures state dir does not exist: $_sd"
    _sdp="$(cd "$_sd" && pwd -P)"
    _fdp="$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P)" \
        || usage_err "$2: cannot resolve: $1"
    case "$_fdp/" in
        "$_sdp"/*) : ;;
        *) usage_err "$2: file must live under the procedures state dir ($_sd): $1" ;;
    esac
    [ -f "$1" ] && [ -r "$1" ] \
        || usage_err "$2: not a readable regular file: $1"
    _META_VALUE="$(cat -- "$1" && printf x)" \
        || usage_err "$2: cannot read: $1"
    _META_VALUE="${_META_VALUE%x}"
}

# usage_err — print "prog: msg" plus the usage text to stderr, then exit 2.
usage_err() { printf '%s: %s\n' "$prog" "$1" >&2; usage >&2; exit 2; }

# _write_via_tmp <path> <mode|keep> — replace <path> with stdin through a temp
# file in the same dir and a rename, so no reader or crash sees it truncated.
# `keep` carries over the current file's mode.
_write_via_tmp() {
    local tmp
    tmp="$(mktemp "${1%/*}/.${1##*/}.XXXXXX")" || return 1
    if [ "$2" = keep ]; then
        if [ -e "$1" ]; then cp -p -- "$1" "$tmp" || return 1; fi
    else
        chmod "$2" "$tmp" || return 1
    fi
    cat > "$tmp" && mv -f -- "$tmp" "$1"
}

# _read_all <path> — print a file verbatim (empty when absent); fails when it
# exists but cannot be read, so a rewrite never drops what it could not read.
_read_all() { [ ! -e "$1" ] || cat -- "$1"; }

# _qrows <root> <match|rest> — quarantine rows of <root> as "<row|tail>\t<row>"
# (match), or every other root's lines unchanged (rest). Quarantine lines are
# "<root>\t<row|tail>\t<row>"; a "tail" is the new text of a glued row.
_qrows() {
    awk -F'\t' -v r="$1" -v m="$2" '
        m == "rest" { if ($1 != r) print; next }
        $1 == r { sub(/^[^\t]*\t/, ""); print }' <<< "$QALL"
}

# _release_quarantine <root> — under <root>'s mistakes lock: refuse unless its
# mistakes.jsonl is committed, then (quarantine lock) move the root's rows back.
_release_quarantine() {
    local st
    if ! st="$(git -C "$1" status --porcelain -- mistakes.jsonl 2>&1)" || [ -n "$st" ]; then
        printf '%s: %s/mistakes.jsonl has uncommitted changes (or git status failed); commit or discard them first\n' \
            "$prog" "$1" >&2
        return 2
    fi
    mkdir -p "${JSONL_QUARANTINE%/*}" || return 1
    mistakes_locked "$JSONL_QUARANTINE_LOCK" _release_rows "$1"
}

_release_rows() {
    local mine rest old jsonl="$1/mistakes.jsonl" n tails
    QALL="$(_read_all "$JSONL_QUARANTINE" && printf x)" || return 1
    QALL="${QALL%x}"
    mine="$(_qrows "$1" match)"
    rest="$(_qrows "$1" rest)"
    if [ -z "$mine" ]; then
        printf '%s: no quarantined rows for %s\n' "$prog" "$1"
        return 0
    fi
    old="$(_read_all "$jsonl" && printf x)" || return 1
    old="${old%x}"
    [ -z "$old" ] || [ "${old: -1}" = $'\n' ] || old="$old"$'\n'
    { printf '%s' "$old"; printf '%s\n' "$mine" | cut -f2-; } | _write_via_tmp "$jsonl" keep || return 1
    if [ -n "$rest" ]; then printf '%s\n' "$rest"; fi | _write_via_tmp "$JSONL_QUARANTINE" 600 || return 1
    n="$(printf '%s\n' "$mine" | wc -l | tr -d ' ')"
    tails="$(printf '%s\n' "$mine" | grep -c '^tail'$'\t')"
    {
        printf '%s: WARNING: released %s quarantined rows into %s.\n' "$prog" "$n" "$jsonl"
        printf '%s: WARNING: they will be re-scanned by the gate; edit out the leak first, and do not commit them by hand.\n' "$prog"
        [ "$tails" -eq 0 ] || printf '%s: WARNING: %s of them are tails of a glued row and may not be valid JSON.\n' "$prog" "$tails"
    } >&2
}

if [ "${1:-}" = "--release-quarantine" ]; then
    [ "$#" -eq 2 ] && [ -d "$2" ] || usage_err "--release-quarantine needs an existing root dir"
    _rq_root="$(cd "$2" && pwd -P)" || usage_err "cannot resolve root: $2"
    mistakes_locked "$(mistakes_lock_path "$_rq_root")" _release_quarantine "$_rq_root"
    _rq_rc=$?
    [ "$_rq_rc" -ne 75 ] || printf '%s: a mistakes lock stayed busy; nothing released\n' "$prog" >&2
    [ "$_rq_rc" -eq 0 ] || exit 1
    exit 0
fi

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
                # -file forms: read the file verbatim into the field (see _read_meta_file).
                --why-file) _read_meta_file "$2" --why-file; WHY="$_META_VALUE"; WHY_FILE=1 ;;
                --source-file) _read_meta_file "$2" --source-file; SOURCE="$_META_VALUE"; SOURCE_FILE=1 ;;
                --evidence-file) _read_meta_file "$2" --evidence-file; EVIDENCE="$_META_VALUE"; EVIDENCE_FILE=1 ;;
            esac
            shift 2 ;;
        --normalize) NORMALIZE_ONLY=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_err "unknown arg '$1'" ;;
    esac
done
unset _META_VALUE

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

# --paths filter. What this loop enforces: every entry is a root-relative path
# ending in .md, located under the record directories ($RECDIR/ or plans/).
# Absolute paths and any `..` segment are rejected so a caller cannot reach
# outside the selected store. A non-.md entry is rejected so a sensitive
# non-record file cannot ride in unvalidated; the root-relative
# `mistakes.jsonl` is the one exception, held apart in JSONL and vetted in
# step 6. The literal `.index` is also tolerated: accepted for caller
# compatibility and dropped, since the gate adds `.index` itself (step 5); the
# drop is announced once on stderr so a caller is not left believing it
# selected the index.
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
_FILTERED=() JSONL=""
for _p in ${PATHS[@]+"${PATHS[@]}"}; do
    case "$_p" in
        /*) usage_err "--paths entry must be root-relative, not absolute: $_p" ;;
        .. | ../* | */.. | */../*) usage_err "--paths entry escapes --root via '..': $_p" ;;
        .index)
            [ -n "${_index_noted:-}" ] || printf '%s: note: ".index" in --paths is ignored; the gate stages the index itself\n' "$prog" >&2
            _index_noted=1
            continue ;;
        mistakes.jsonl) JSONL=mistakes.jsonl; continue ;;
        *.md)
            case "$_p" in
                "$RECDIR"/*|plans/*) _FILTERED+=("$_p") ;;
                *) usage_err "--paths entry is outside the record directories ($RECDIR/, plans/): $_p" ;;
            esac
            ;;
        *) usage_err "--paths entry is not a record .md file: $_p" ;;
    esac
done
unset _p _index_noted
[ "${#_FILTERED[@]}" -gt 0 ] || [ -n "$JSONL" ] || usage_err "--paths has no record .md entries"
PATHS=(${_FILTERED[@]+"${_FILTERED[@]}"})
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
    _queue "$1" "$2"
    printf '%s: BLOCK [%s]: %s\n' "$prog" "$1" "$2" >&2
    printf '%s: re-invoke this root with the offending path(s) removed once fixed/queued.\n' "$prog" >&2
    exit 1
}

# _queue <check> <message> — append one note to the grooming queue. Shared by
# _abort and by the non-blocking mistakes.jsonl quarantine.
_queue() {
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
    for rel in ${PATHS[@]+"${PATHS[@]}"}; do
        case "$rel" in
            *.md)
                abs="$ROOT/$rel"
                # Refuse a symlinked record: _normalize_file and the rename
                # below would write THROUGH the link to a file outside the
                # store, and validation would read the target while git would
                # commit only the link.
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

# _safe_pull <check> <msg> — `pull --rebase --autostash` that never lets a bad
# autostash through. A conflicting autostash pop still exits 0 and leaves
# unmerged paths (conflict markers) that the later `git add` would commit; so on
# any unmerged path, reset to the pre-pull HEAD and pop the stash there (it
# applies cleanly onto the HEAD it was made from), then abort. Any other pull
# failure restores a left-behind stash entry rather than dropping it.
_safe_pull() {
    local check="$1" msg="$2" pre nstash conflicts
    pre="$(git -C "$ROOT" rev-parse HEAD)"
    nstash="$(git -C "$ROOT" stash list | wc -l)"
    if ! git -C "$ROOT" pull --rebase --autostash >/dev/null 2>&1; then
        git -C "$ROOT" rebase --abort >/dev/null 2>&1 || true
        _restore_stash "$nstash"
        _abort "$check" "$msg"
    fi
    conflicts="$(git -C "$ROOT" ls-files -u | cut -f2 | sort -u | tr '\n' ' ')"
    if [ -n "$conflicts" ]; then
        git -C "$ROOT" reset -q --hard "$pre"
        _restore_stash "$nstash"
        _abort "$check" "upstream conflicts with local uncommitted edits in: ${conflicts% }; reset to pre-pull HEAD, local edits restored, nothing committed"
    fi
}

# _restore_stash <count-before> — pop an autostash entry the pull left in
# `git stash list`; if it will not apply, say so (it stays in the list).
_restore_stash() {
    [ "$(git -C "$ROOT" stash list | wc -l)" -gt "$1" ] || return 0
    git -C "$ROOT" stash pop -q >/dev/null 2>&1 \
        || printf '%s: WARN: autostash did not re-apply in %s; kept as stash@{0}\n' "$prog" "$ROOT" >&2
}

# ---- step 0: union-merge mistakes.jsonl ----
# Every machine appends to mistakes.jsonl, so two machines' appends conflict
# under a plain merge and step 1's autostash/rebase would abort this store's
# gate on every later run. info/attributes is per-clone, so set it here, once.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _attrs="$(git -C "$ROOT" rev-parse --git-path info/attributes)"
    case "$_attrs" in /*) ;; *) _attrs="$ROOT/$_attrs" ;; esac
    if ! grep -qxF 'mistakes.jsonl merge=union' "$_attrs" 2>/dev/null; then
        { mkdir -p "$(dirname "$_attrs")" \
            && { [ ! -s "$_attrs" ] || [ -z "$(tail -c1 "$_attrs")" ] || echo; } >> "$_attrs" \
            && printf 'mistakes.jsonl merge=union\n' >> "$_attrs"; } 2>/dev/null \
            || _abort union-merge "cannot write $_attrs"
    fi
    unset _attrs
fi

# ---- step 1: pull --rebase (only with an upstream) ----
# Runs BEFORE normalize: normalization rewrites and `git mv`s tracked records,
# and `git pull --rebase` refuses a dirty worktree/index. Sync first, then
# normalize the local records against current upstream. --autostash: tracked
# files outside --paths (log-record.sh appends to mistakes.jsonl) are routinely
# dirty; without it every pull fails and the gate blocks forever.
if git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    _safe_pull pull "initial 'git pull --rebase' failed for $ROOT; tree left clean"
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
if [ "${#REC_PATHS[@]}" -gt 0 ] && [ -x "$ROOT/scripts/validate.sh" ]; then
    if ! vs_out="$( cd "$ROOT" && ./scripts/validate.sh ${REC_PATHS[@]+"${REC_PATHS[@]}"} 2>&1 )"; then
        _abort per-store-validate "$(printf '%s' "$vs_out" | tr '\n' ' ')"
    fi
fi

# ---- step 5: rebuild index into the same commit ----
_rebuild_index
# The gate — not the caller — stages the rebuilt index. FINAL_PATHS holds only
# record .md paths (any caller-supplied .index was dropped up front; mistakes.jsonl
# is staged separately in step 6); append it now so the `git add` below stages
# the index alongside the records it describes.
# Stores that gitignore `.index/` keep it local-only: `git add` refuses an
# ignored path, which would block every commit, so skip it there. --no-index:
# without it, index files tracked before the ignore rule make check-ignore say
# "not ignored", and `git add .index` then fails on the new ignored files.
INDEX_IGNORED=
if git -C "$ROOT" check-ignore -q --no-index .index 2>/dev/null; then
    INDEX_IGNORED=1
else
    FINAL_PATHS+=(".index")
fi

# ---- step 6: structured commit ----
# Constrain the transcript-derived commit metadata (what/why/source/evidence)
# before it lands verbatim in the commit body. The baseline sanitization scans
# record FILES only; these fields bypass it entirely. They are meant to be
# bounded pointers (session id, line ranges), so cap their length and run them
# through the same leak-class check — a personal path, token, or key must not
# ride into git history via a commit trailer.
META_CAP=2048
for _mn in what why source evidence; do
    case $_mn in
        what) _mv="$WHAT" ;;
        why) _mv="$WHY" ;;
        source) _mv="$SOURCE" ;;
        evidence) _mv="$EVIDENCE" ;;
    esac
    # Byte count (not character count): the cap is a byte budget, and ${#_mv}
    # counts characters, which under a UTF-8 locale undercounts a multi-byte
    # field. LC_ALL=C wc -c counts raw bytes.
    _mb=$(printf '%s' "$_mv" | LC_ALL=C wc -c | tr -d '[:space:]')
    if [ "$_mb" -gt "$META_CAP" ]; then
        _abort metadata "--$_mn (${_mb} bytes) exceeds the ${META_CAP}-byte pointer cap"
    fi
done
unset _mn _mv _mb
_meta_tmp="$(mktemp)"
printf '%s\n%s\n%s\n%s\n' "$WHAT" "$WHY" "$SOURCE" "$EVIDENCE" > "$_meta_tmp"
if ! _meta_out="$(bash "$SCRIPT_DIR/check-sanitization.sh" "$_meta_tmp" 2>&1)"; then
    rm -f "$_meta_tmp"
    _abort metadata "commit metadata leaks unsafe content: $(printf '%s' "$_meta_out" | tr '\n' ' ')"
fi
rm -f "$_meta_tmp"

if [ "${#FINAL_PATHS[@]}" -gt 0 ]; then
    git -C "$ROOT" add -- "${FINAL_PATHS[@]}" 2>/dev/null || \
        _abort commit "git add failed for: ${FINAL_PATHS[*]}"
fi
# Ignored .index that still has tracked files: restage just those.
if [ -n "$INDEX_IGNORED" ]; then
    git -C "$ROOT" add -u -- .index 2>/dev/null || _abort commit "git add -u failed for: .index"
fi

# _stage_jsonl — stage mistakes.jsonl and vet exactly the rows this commit adds:
# the STAGED blob vs HEAD (the whole blob on an unborn branch), so what was
# scanned is what gets committed. Fails closed: a git error, a NUL byte (git
# would call the file binary and show no rows), a removed row (the file is
# append-only), a change that yields no added rows, or a scanner failure all
# abort. One removal is allowed: HEAD's newline-less last row, when the first
# added row starts with it (re-terminated, or a row glued on); the glued line
# is scanned whole, since a token can straddle the join. A row that trips
# check-sanitization --strict moves to the quarantine (local, outside git,
# mode 600) with a queue note naming only its line and leak class, so one
# leak cannot wedge every later append; of a glued row only the new tail moves.
_stage_jsonl() {
    local f="$JSONL" n_all n_text diff added="" ln keep row cls pcls kind
    [ -L "$ROOT/$f" ] && _abort path "$f is a symlink (refusing to follow)"
    [ -f "$ROOT/$f" ] || _abort path "path does not exist: $f"
    git -C "$ROOT" add -- "$f" 2>/dev/null || _abort commit "git add failed for: $f"
    n_all="$(git -C "$ROOT" cat-file blob ":$f" | LC_ALL=C wc -c)" \
        && n_text="$(git -C "$ROOT" cat-file blob ":$f" | LC_ALL=C tr -d '\000' | LC_ALL=C wc -c)" \
        || _abort jsonl "cannot read the staged $f"
    [ "$n_all" = "$n_text" ] || _abort jsonl "$f contains a NUL byte; refusing to treat it as text"
    if git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        diff="$(git -C "$ROOT" diff --cached -U0 --text --no-ext-diff --no-textconv HEAD -- "$f")" \
            || _abort jsonl "git diff of the staged $f failed"
        # -U0 hunk header "@@ -a,b +c,d @@": added rows are numbered from c.
        # Emits "<line>\t<prefix-bytes-from-HEAD>\t<line text>"; exits 1 on a removal
        # other than the newline-less last row described above.
        added="$(printf '%s\n' "$diff" | LC_ALL=C awk '
            /^@@/ { if (pend) exit 1
                    split($3, a, ","); n = substr(a[1], 2) + 0; h = 1; pend = 0; eof = 0; add = 0; next }
            !h { next }
            /^-/ { if (pend || add) exit 1; pend = 1; rem = substr($0, 2); next }
            /^\\/ { if (pend && !add) eof = 1; next }
            /^\+/ { row = substr($0, 2); keep = 0
                    if (pend) {
                        if (!eof || index(row, rem) != 1) exit 1
                        keep = length(rem); pend = 0
                    }
                    printf "%d\t%d\t%s\n", n, keep, row; n++; add = 1 }
            END { if (pend) exit 1 }')" \
            || _abort jsonl "$f is append-only, but this commit removes or rewrites a row"
        if [ -z "$added" ] && ! git -C "$ROOT" diff --cached --quiet HEAD -- "$f"; then
            _abort jsonl "$f differs from HEAD but no added rows could be read; failing closed"
        fi
    else
        added="$(git -C "$ROOT" cat-file blob ":$f" | awk '{ printf "%d\t0\t%s\n", NR, $0 }')" \
            || _abort jsonl "cannot read the staged $f"
    fi

    JSONL_DROP="" JSONL_QROWS=() JSONL_ADDED=0
    while IFS=$'\t' read -r ln keep row; do
        _split_glued "$row" "$keep"
        [ -n "$JSONL_TAIL" ] || continue
        JSONL_ADDED=$(( JSONL_ADDED + 1 ))
        cls="$(_leak_class "$row")" || _abort jsonl "the scanner failed on $f line $ln; failing closed"
        [ -n "$cls" ] || continue
        # The prefix is already in history: if it alone leaks, quarantining
        # cannot unleak it, so judge the new tail alone or the store wedges.
        if [ "$keep" -gt 0 ] && pcls="$(_leak_class "$JSONL_HEAD")" && [ -n "$pcls" ]; then
            cls="$(_leak_class "$JSONL_TAIL")" || _abort jsonl "the scanner failed on $f line $ln; failing closed"
            [ -n "$cls" ] || continue
        fi
        if [ "$keep" -gt 0 ]; then kind=tail; else kind=row; fi
        JSONL_QROWS+=("$ROOT_PHYS"$'\t'"$kind"$'\t'"$JSONL_TAIL")
        JSONL_DROP="$JSONL_DROP $ln:$keep"
        _queue jsonl-quarantine "$f line $ln: $cls; row moved to $JSONL_QUARANTINE, not committed; after review: commit-records.sh --release-quarantine $ROOT"
    done <<< "$added"
    [ -n "$JSONL_DROP" ] || return 0

    # Drop the quarantined rows (a glued row keeps its old prefix) from the
    # staged blob AND, under the lock log-record.sh appends under, from the
    # working file, so the tree stays clean and matches the commit.
    local mode blob
    mode="$(git -C "$ROOT" ls-files -s -- "$f" | awk '{ print $1; exit }')"
    blob="$(git -C "$ROOT" cat-file blob ":$f" | _drop_lines "$JSONL_DROP" \
        | git -C "$ROOT" hash-object -w --stdin)" \
        && git -C "$ROOT" update-index --cacheinfo "${mode:-100644},$blob,$f" \
        || _abort jsonl "cannot restage $f without its quarantined rows"
    mistakes_locked "$(mistakes_lock_path "$ROOT")" _quarantine_rows \
        || _abort jsonl "cannot quarantine rows of $f (mistakes lock busy or write failed); working file unchanged"
    JSONL_QUARANTINED="${#JSONL_QROWS[@]}"
}

# _split_glued <line> <n> — JSONL_HEAD = its first <n> bytes (HEAD's glued
# prefix), JSONL_TAIL = the rest (the new text).
_split_glued() { local LC_ALL=C; JSONL_HEAD="${1:0:$2}"; JSONL_TAIL="${1:$2}"; }

# _leak_class <text> — the --strict leak classes <text> trips, comma-joined
# (empty when clean); fails when the scanner fails without naming a class.
_leak_class() {
    local out cls
    out="$(printf '%s\n' "$1" | bash "$SCRIPT_DIR/check-sanitization.sh" --strict - 2>&1)" && return 0
    cls="$(printf '%s\n' "$out" | sed -n 's/^.* — \(.*\) (line [0-9]*)$/\1/p' | paste -sd, -)"
    [ -n "$cls" ] && printf '%s' "$cls"
}

# _quarantine_rows — under the mistakes lock: add JSONL_QROWS to the private
# quarantine (under its own lock: it is shared by every root), then drop
# JSONL_DROP from the working mistakes.jsonl.
_quarantine_rows() {
    local content
    mkdir -p "${JSONL_QUARANTINE%/*}" \
        && mistakes_locked "$JSONL_QUARANTINE_LOCK" _append_quarantine || return 1
    content="$(_drop_lines "$JSONL_DROP" < "$ROOT/$JSONL" && printf x)" || return 1
    printf '%s' "${content%x}" | _write_via_tmp "$ROOT/$JSONL" keep
}

_append_quarantine() {
    local old
    old="$(_read_all "$JSONL_QUARANTINE" && printf x)" || return 1
    { printf '%s' "${old%x}"; printf '%s\n' "${JSONL_QROWS[@]}"; } | _write_via_tmp "$JSONL_QUARANTINE" 600
}

# _drop_lines "<n>:<keep> ..." — copy stdin to stdout, dropping line <n>, or
# cutting it to its first <keep> bytes when <keep> > 0.
_drop_lines() {
    LC_ALL=C awk -v d="$1" '
        BEGIN { n = split(d, a, " "); for (i = 1; i <= n; i++) { split(a[i], p, ":"); x[p[1]] = p[2] } }
        !(NR in x) { print; next }
        x[NR] > 0 { print substr($0, 1, x[NR]) }'
}

JSONL_QUARANTINED=""
[ -z "$JSONL" ] || _stage_jsonl
if git -C "$ROOT" diff --cached --quiet; then
    printf '%s: nothing to commit\n' "$prog"
    exit 0
fi

subject="records(${STORE_BASENAME}): ${WHAT}"
# Only the rebuilt .index is left (e.g. every row quarantined): commit it under
# its own subject, so the tree stays clean and WHAT does not claim records.
if [ -z "$(git -C "$ROOT" diff --cached --name-only | grep -v '^\.index/')" ]; then
    subject="records(${STORE_BASENAME}): refresh index"
elif [ -n "$JSONL_QUARANTINED" ]; then
    # The caller counted rows before the quarantine: restate what commits.
    _kept=$(( JSONL_ADDED - JSONL_QUARANTINED ))
    _noun="mistakes"; [ "$_kept" -ne 1 ] || _noun="mistake"
    subject="$(printf '%s' "$subject" | sed -E "s/[0-9]+ mistakes?/$_kept $_noun/") ($JSONL_QUARANTINED quarantined)"
fi
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
        _safe_pull push "push rejected and 'pull --rebase' could not fast-forward; rebase aborted, tree left clean, no force; files: ${FINAL_PATHS[*]}"
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
