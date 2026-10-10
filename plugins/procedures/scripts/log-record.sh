#!/usr/bin/env bash
# log-record.sh — the DETERMINISTIC half of `/update-records <kind>`.
#
# PLUGIN ADAPTATION: no materialized views — the upstream gen-* regen steps are
# removed; `/how-do-i` compiles views on demand.
#
# Consolidates the four record-writers (log-mistake, record-decision,
# record-solution, record-failure-mode) into one script with four
# subcommands. The `/update-records` SKILL gathers the JUDGMENT fields (category,
# description, recurrence_of, pattern, keywords, prose body) and calls this
# script, which does only the mechanical work: build the JSON / write the file.
#
# HARD RULE: every JSON object is built with `jq -n --arg` — never an inline
# echoed brace-literal. The old log-mistake/SKILL.md echoed the JSON object as a
# single-quoted string, which is the apostrophe-in-jq bug class (a `'` inside
# that quoted literal truncates the JSON). This script fixes it by construction.
#
# Subcommands:
#   mistake       append a row to mistakes.jsonl, under the mistakes lock that
#                 commit-records.sh's quarantine rewrite also takes (see
#                 lib/mistakes-lock.sh); an unterminated last row is ended first.
#                 --source <id>:<a>-<b> names the transcript lines, sets the
#                 session, and refuses a row whose lines an existing row with
#                 that id already covers.
#   decision      write records/decisions/<date>-<slug>.md
#   solution      write records/solutions/<date>-<slug>.md
#   failure-mode  write/update records/failure-modes/<slug>.md
#                 (gated: >=3 occurrences of the pattern in mistakes.jsonl first)
#
# `--project <owner/repo>` is OPTIONAL on decision/solution/failure-mode and
# writes the frontmatter `project:` key marking a record as repo-scoped
# on. Omitted when not passed — a record with no `project:` is corpus-wide, and
# an EMPTY `project:` would be neither (unmatchable, and rejected by
# lint-frontmatter.sh's shape check).
#
# Env overrides (used by tests so a dry-run never mutates committed records):
#   MISTAKES_JSONL        path to the jsonl (default: $HOME/.claude/mistakes.jsonl,
#                         or $CODEX_ROOT/mistakes.jsonl when CODEX_ROOT is set).
#                         Also the corpus the failure-mode >=3 gate counts.
#   DECISIONS_DIR / SOLUTIONS_DIR / FAILURE_MODES_DIR
#                         override the target dirs (default: records/<kind>, or
#                         references/<kind> — the legacy fallback — when $ROOT
#                         has no records/ dir yet; see stores_records_dir).
#   CODEX_RECORDS_DIR     forces that records dirname (see stores_records_dir).
#
# When CODEX_ROOT is set, every target is derived from it and these overrides
# can no longer move a write: each one set must resolve (physically) to the
# value derived from CODEX_ROOT, or the script refuses before writing. The
# headless librarian pins CODEX_ROOT per call, but a `export DECISIONS_DIR=...
# && <pinned call>` from another settings source's allow rule would otherwise
# send its record anywhere, such as ~/.claude/agents. Unset CODEX_ROOT keeps
# the overrides as they were (tests, interactive use).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stores.sh
source "$SCRIPT_DIR/lib/stores.sh"
# shellcheck source=lib/mistakes-lock.sh
source "$SCRIPT_DIR/lib/mistakes-lock.sh"
# PLUGIN ADAPTATION: data root defaults to the host codex (~/.claude), not this
# plugin install dir — upstream these scripts live inside the codex repo itself.
ROOT="${CODEX_ROOT:-$HOME/.claude}"

die() { printf 'log-record: %s\n' "$1" >&2; exit 1; }

# _phys <path> — <path> made absolute and physical: its deepest existing
# ancestor dir resolved with `pwd -P`, the not-yet-existing rest appended as
# written. Two paths compare equal only when they name the same file.
_phys() {
    local p="$1" rest="" d
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ]; do
        rest="/${p##*/}$rest"
        p="${p%/*}"
        [ -n "$p" ] || p=/
    done
    d="$(cd "$p" && pwd -P)" || return 1
    printf '%s%s' "${d%/}" "$rest"
}

# _pin_to_root <var> <derived> — when CODEX_ROOT is set, refuse an override in
# <var> that does not resolve to <derived>, the path CODEX_ROOT implies.
_pin_to_root() {
    local v="${!1:-}" got want
    [ -n "${CODEX_ROOT:-}" ] && [ -n "$v" ] || return 0
    got="$(_phys "$v")" || die "cannot resolve $1: $v"
    want="$(_phys "$2")" || die "cannot resolve $2"
    [ "$got" = "$want" ] \
        || die "refusing $1='$v': with CODEX_ROOT set it must be $2"
}

# --- paths (overridable for tests; pinned to CODEX_ROOT when it is set) ---
# Record-tree dirname is resolved per root: records/ canonical, references/ the
# legacy fallback when $ROOT has not been renamed yet (see stores_records_dir).
if [ -n "${CODEX_ROOT:-}" ]; then
    RECORDS_DIRNAME="$(CODEX_RECORDS_DIR='' stores_records_dir "$ROOT")"
    [ -z "${CODEX_RECORDS_DIR:-}" ] || [ "$CODEX_RECORDS_DIR" = "$RECORDS_DIRNAME" ] \
        || die "refusing CODEX_RECORDS_DIR='$CODEX_RECORDS_DIR': with CODEX_ROOT set it must be $RECORDS_DIRNAME"
    _pin_to_root MISTAKES_JSONL "$ROOT/mistakes.jsonl"
    _pin_to_root DECISIONS_DIR "$ROOT/$RECORDS_DIRNAME/decisions"
    _pin_to_root SOLUTIONS_DIR "$ROOT/$RECORDS_DIRNAME/solutions"
    _pin_to_root FAILURE_MODES_DIR "$ROOT/$RECORDS_DIRNAME/failure-modes"
    # Use the derived values, not the (equivalent) overrides.
    MISTAKES_JSONL="$ROOT/mistakes.jsonl"
    DECISIONS_DIR="$ROOT/$RECORDS_DIRNAME/decisions"
    SOLUTIONS_DIR="$ROOT/$RECORDS_DIRNAME/solutions"
    FAILURE_MODES_DIR="$ROOT/$RECORDS_DIRNAME/failure-modes"
else
    RECORDS_DIRNAME="$(stores_records_dir "$ROOT")"
    MISTAKES_JSONL="${MISTAKES_JSONL:-$HOME/.claude/mistakes.jsonl}"
    DECISIONS_DIR="${DECISIONS_DIR:-$ROOT/$RECORDS_DIRNAME/decisions}"
    SOLUTIONS_DIR="${SOLUTIONS_DIR:-$ROOT/$RECORDS_DIRNAME/solutions}"
    FAILURE_MODES_DIR="${FAILURE_MODES_DIR:-$ROOT/$RECORDS_DIRNAME/failure-modes}"
fi

# Path-forming arguments. The headless librarian may call this script with
# open arguments drawn from untrusted transcripts, so every value that becomes
# part of a file path is checked here, not by the caller: a slug is one safe
# filename component (see stores_check_slug: ASCII only, no `/`, no `..`, and
# never a name Claude Code auto-loads as instructions, such as CLAUDE.md), a
# date is exactly YYYY-MM-DD.
_check_slug() {
    local why
    why="$(stores_check_slug "$1")" || die "invalid --slug '$1': $why"
}
_check_date() {
    local LC_ALL=C
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
        || die "invalid --date '$1': expected YYYY-MM-DD"
}
# _check_target <file> <dir> — defence in depth after the argument checks:
# refuse unless <file>'s physical parent is exactly the physical <dir>, and
# refuse to write through a symlink.
_check_target() {
    local want got
    want="$(cd "$2" 2>/dev/null && pwd -P)" || die "cannot resolve records dir: $2"
    got="$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || die "cannot resolve output dir for: $1"
    [ "$got" = "$want" ] || die "refusing to write outside $want: $1"
    [ ! -L "$1" ] || die "refusing to write through a symlink: $1"
}

# ===========================================================================
# mistake
# ===========================================================================
cmd_mistake() {
    local ts project session category trigger description correction
    local skill severity scenario_matched pattern face recurrence_of source
    source=""
    ts="" project="" session="" category="" trigger="" description=""
    correction="" skill="" severity="" scenario_matched="" pattern=""
    face="" recurrence_of=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --ts)              ts="$2"; shift 2 ;;
            --project)         project="$2"; shift 2 ;;
            --session)         session="$2"; shift 2 ;;
            --category)        category="$2"; shift 2 ;;
            --trigger)         trigger="$2"; shift 2 ;;
            --description)     description="$2"; shift 2 ;;
            --correction)      correction="$2"; shift 2 ;;
            --skill)           skill="$2"; shift 2 ;;
            --severity)        severity="$2"; shift 2 ;;
            --scenario-matched) scenario_matched="$2"; shift 2 ;;
            --pattern)         pattern="$2"; shift 2 ;;
            --face)            face="$2"; shift 2 ;;
            --recurrence-of)   recurrence_of="$2"; shift 2 ;;
            --source)          source="$2"; shift 2 ;;
            *) die "unknown mistake flag: $1" ;;
        esac
    done

    [ -n "$ts" ] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$category" ]    || die "mistake requires --category"
    [ -n "$description" ] || die "mistake requires --description"
    [ -n "$correction" ]  || die "mistake requires --correction"
    [ -n "$severity" ]    || die "mistake requires --severity"
    [ -n "$trigger" ]     || die "mistake requires --trigger"

    # --source <id>:<a>-<b> names the transcript lines that show the mistake;
    # its id fills --session when that is absent.
    if [ -n "$source" ]; then
        [[ "$source" =~ ^([^[:space:]]+):([0-9]{1,9})-([0-9]{1,9})$ ]] \
            || die "--source must be <session-id>:<first>-<last> (got: $source)"
        [ $((10#${BASH_REMATCH[2]})) -le $((10#${BASH_REMATCH[3]})) ] \
            || die "--source range runs backwards (got: $source)"
        [ -n "$session" ] || session="${BASH_REMATCH[1]}"
    fi
    [ -n "$session" ] || printf 'log-record: note: no session on this row (pass --session or --source)\n' >&2

    # scenario_matched is always present in the schema; the literal token "null"
    # means JSON null, anything else (incl. empty) is the string form the
    # originals used.  Build the base object, then conditionally add the
    # OMIT-WHEN-EMPTY keys (pattern, face, recurrence_of) so they never appear
    # as empty strings.  Every value goes through --arg (no inline JSON).
    local row
    row="$(
        jq -nc \
            --arg ts "$ts" \
            --arg project "$project" \
            --arg session "$session" \
            --arg category "$category" \
            --arg trigger "$trigger" \
            --arg description "$description" \
            --arg correction "$correction" \
            --arg skill "$skill" \
            --arg severity "$severity" \
            --arg scenario "$scenario_matched" \
            --arg pattern "$pattern" \
            --arg face "$face" \
            --arg recurrence_of "$recurrence_of" \
            --arg source "$source" \
            '{ts:$ts, project:$project, session:$session, category:$category,
              trigger:$trigger, description:$description, correction:$correction,
              skill:$skill, severity:$severity}
             | .scenario_matched = (if $scenario == "null" then null else $scenario end)
             | (if $pattern       != "" then .pattern       = $pattern       else . end)
             | (if $face          != "" then .face          = $face          else . end)
             | (if $recurrence_of != "" then .recurrence_of = $recurrence_of else . end)
             | (if $source        != "" then .source        = $source        else . end)'
    )"

    mkdir -p "$(dirname "$MISTAKES_JSONL")"
    [ ! -L "$MISTAKES_JSONL" ] || die "refusing to append through a symlink: $MISTAKES_JSONL"
    local rc=0
    mistakes_locked "$(mistakes_lock_path "$(dirname "$MISTAKES_JSONL")")" _append_row "$row" "$source" || rc=$?
    # 75 is the lock helper's timeout; any other failure is the write itself.
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && die "could not take the mistakes.jsonl lock; row not appended"; die "row not appended"; }
}

# _source_overlap <source> — print the ts of the first row, in this file or any
# store root's mistakes.jsonl, whose source shares a line with <source> (same
# id, ranges overlap or touch). Unparseable lines are skipped; an unreadable
# file is noted on stderr and skipped (fail open: it must not block logging).
# A row with no ts prints "?" so it still counts as a hit.
_source_overlap() {
    local f hit files=("$MISTAKES_JSONL")
    for f in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
        [ "$f/mistakes.jsonl" -ef "$MISTAKES_JSONL" ] || files+=("$f/mistakes.jsonl")
    done
    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        # jq emits only the first hit itself (no `head`, so a closed pipe cannot
        # masquerade as a read failure): any non-zero exit is a real one.
        hit="$(jq -nRr --arg src "$1" '
            def parse: capture("^(?<id>.+):(?<a>[0-9]+)-(?<b>[0-9]+)$")
                | .a |= tonumber | .b |= tonumber;
            ($src | parse) as $n
            | first(inputs | fromjson? | select(type == "object" and (.source | type) == "string")
            | ((.source | parse?) // empty) as $o
            | select($o.id == $n.id and $o.a <= $n.b and $n.a <= $o.b)
            | (.ts | if type == "string" and . != "" then . else "?" end))' "$f")" \
            || { printf 'log-record: note: could not read %s; duplicate check skipped for it\n' "$f" >&2; continue; }
        [ -z "$hit" ] || { printf '%s\n' "$hit"; return 0; }
    done
}

# _append_row <row> [<source>] — append one row, first ending an unterminated
# last row: a row glued onto it would read as a rewrite of a committed row,
# which commit-records.sh refuses. A <source> that an existing row already
# covers appends nothing; the check runs under the same lock as the append so
# parallel identical calls cannot both pass it.
_append_row() {
    local seen=""
    [ -z "${2:-}" ] || seen="$(_source_overlap "$2")"
    if [ -n "$seen" ]; then
        printf 'log-record: duplicate: source %s lines %s already logged (row ts %s); nothing appended\n' \
            "${2%:*}" "${2##*:}" "$seen" >&2
        return 0
    fi
    if [ -s "$MISTAKES_JSONL" ] && [ -n "$(tail -c1 "$MISTAKES_JSONL")" ]; then
        printf '\n' >> "$MISTAKES_JSONL" || return 1
    fi
    printf '%s\n' "$1" >> "$MISTAKES_JSONL" || return 1
    printf 'log-record: appended mistake to %s\n' "$MISTAKES_JSONL" >&2
}

# ===========================================================================
# decision
# ===========================================================================
cmd_decision() {
    local slug date title keywords links status summary body force project
    slug="" date="" title="" keywords="[]" links="{}" status="active"
    summary="" body="" force="" project=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)     slug="$2"; shift 2 ;;
            --date)     date="$2"; shift 2 ;;
            --title)    title="$2"; shift 2 ;;
            --keywords) keywords="$2"; shift 2 ;;
            --links)    links="$2"; shift 2 ;;
            --status)   status="$2"; shift 2 ;;
            --project)  project="$2"; shift 2 ;;
            --summary)  summary="$2"; shift 2 ;;
            --body)     body="$2"; shift 2 ;;
            --force)    force="1"; shift 1 ;;
            *) die "unknown decision flag: $1" ;;
        esac
    done
    [ -n "$slug" ]    || die "decision requires --slug"
    [ -n "$date" ]    || date="$(date -u +%Y-%m-%d)"
    _check_slug "$slug"; _check_date "$date"
    [ -n "$title" ]   || title="$slug"
    [ -n "$summary" ] || summary="$title"

    local id="dec.${date}-${slug}"
    local file="$DECISIONS_DIR/${date}-${slug}.md"
    mkdir -p "$DECISIONS_DIR"
    _check_target "$file" "$DECISIONS_DIR"

    if [ -f "$file" ]; then
        if [ -z "$force" ]; then
            die "decision '$slug' already exists at $file — this script does not merge; hand-edit the file directly to add/revise content (every real update to these records has been made this way), or re-run with --force to OVERWRITE THE ENTIRE FILE (destroys all existing content — only for an intentional full rewrite)."
        fi
        printf 'log-record: --force set — overwriting existing %s (prior content will be discarded)\n' "$file" >&2
    fi

    if [ -z "$body" ]; then
        body="$(cat <<EOF
## Goal
Stated: [pending]
Real: [pending]

## Values protocol
[pending]

## Chosen path
$summary

## Autonomy verdict
[pending]

## Consequences foreseen
[pending]

## Consequences that materialized
[pending]

## Outcome
[pending]

## Process-soundness
[pending]

## Regrets
[pending]
EOF
)"
    fi

    {
        printf -- '---\n'
        printf 'id: %s\n' "$id"
        printf 'kind: decision\n'
        printf 'date: %s\n' "$date"
        printf 'keywords: %s\n' "$keywords"
        printf 'links: %s\n' "$links"
        printf 'status: %s\n' "$status"
        # OPTIONAL, and OMITTED when empty: an empty `project:` is not "no
        # project", it is a malformed value the shape lint rejects and the
        # --project filter can never match.
        [ -n "$project" ] && printf 'project: %s\n' "$project"
        printf -- '---\n'
        printf '# %s\n\n' "$title"
        printf '%s\n' "$body"
    } > "$file"

    printf 'log-record: wrote %s\n' "$file" >&2
}

# ===========================================================================
# solution
# ===========================================================================
cmd_solution() {
    local slug date title keywords links status situation_tags resolve_after
    local summary body force project
    slug="" date="" title="" keywords="[]" links="{}" status="resolved"
    situation_tags="[]" resolve_after="" summary="" body="" force="" project=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)           slug="$2"; shift 2 ;;
            --date)           date="$2"; shift 2 ;;
            --title)          title="$2"; shift 2 ;;
            --keywords)       keywords="$2"; shift 2 ;;
            --links)          links="$2"; shift 2 ;;
            --status)         status="$2"; shift 2 ;;
            --project)        project="$2"; shift 2 ;;
            --situation-tags) situation_tags="$2"; shift 2 ;;
            --resolve-after)  resolve_after="$2"; shift 2 ;;
            --summary)        summary="$2"; shift 2 ;;
            --body)           body="$2"; shift 2 ;;
            --force)          force="1"; shift 1 ;;
            *) die "unknown solution flag: $1" ;;
        esac
    done
    [ -n "$slug" ]    || die "solution requires --slug"
    [ -n "$date" ]    || date="$(date -u +%Y-%m-%d)"
    _check_slug "$slug"; _check_date "$date"
    [ -n "$title" ]   || title="$slug"
    [ -n "$summary" ] || summary="$title"
    [ -n "$resolve_after" ] || resolve_after="$(date -u -d '+3 months' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"

    local id="sol.${date}-${slug}"
    local file="$SOLUTIONS_DIR/${date}-${slug}.md"
    mkdir -p "$SOLUTIONS_DIR"
    _check_target "$file" "$SOLUTIONS_DIR"

    if [ -f "$file" ]; then
        if [ -z "$force" ]; then
            die "solution '$slug' already exists at $file — this script does not merge; hand-edit the file directly to add/revise content (every real update to these records has been made this way), or re-run with --force to OVERWRITE THE ENTIRE FILE (destroys all existing content — only for an intentional full rewrite)."
        fi
        printf 'log-record: --force set — overwriting existing %s (prior content will be discarded)\n' "$file" >&2
    fi

    if [ -z "$body" ]; then
        body="$(cat <<EOF
## Symptom
[pending]

## Rule
$summary

## Check
[optional]

## Recipe
[optional]
EOF
)"
    fi

    {
        printf -- '---\n'
        printf 'id: %s\n' "$id"
        printf 'kind: solution\n'
        printf 'date: %s\n' "$date"
        printf 'keywords: %s\n' "$keywords"
        printf 'links: %s\n' "$links"
        printf 'status: %s\n' "$status"
        # OPTIONAL, and OMITTED when empty — see cmd_decision.
        [ -n "$project" ] && printf 'project: %s\n' "$project"
        printf 'situation_tags: %s\n' "$situation_tags"
        printf 'resolve_after: %s\n' "$resolve_after"
        printf -- '---\n'
        printf '# %s\n\n' "$title"
        printf '%s\n' "$body"
    } > "$file"

    printf 'log-record: wrote %s\n' "$file" >&2
}

# ===========================================================================
# failure-mode
# ===========================================================================
cmd_failure_mode() {
    local slug date keywords rule mistake correct face_of status
    local links_scenario links_criterion mega skip_gate force project
    slug="" date="" keywords="[]" rule="" mistake="" correct=""
    face_of="" status="active" links_scenario="" links_criterion=""
    mega="" skip_gate="" force="" project=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)            slug="$2"; shift 2 ;;
            --date)            date="$2"; shift 2 ;;
            --keywords)        keywords="$2"; shift 2 ;;
            --rule)            rule="$2"; shift 2 ;;
            --mistake)         mistake="$2"; shift 2 ;;
            --correct)         correct="$2"; shift 2 ;;
            --face-of)         face_of="$2"; shift 2 ;;
            --status)          status="$2"; shift 2 ;;
            --project)         project="$2"; shift 2 ;;
            --links-scenario)  links_scenario="$2"; shift 2 ;;
            --links-criterion) links_criterion="$2"; shift 2 ;;
            --mega)            mega="$2"; shift 2 ;;
            --skip-gate)       skip_gate="1"; shift 1 ;;
            --force)           force="1"; shift 1 ;;
            *) die "unknown failure-mode flag: $1" ;;
        esac
    done
    [ -n "$slug" ] || die "failure-mode requires --slug"
    [ -n "$rule" ] || die "failure-mode requires --rule"
    [ -n "$date" ] || date="$(date -u +%Y-%m-%d)"
    _check_slug "$slug"; _check_date "$date"

    local id="fm.${slug}"
    local file="$FAILURE_MODES_DIR/${slug}.md"
    mkdir -p "$FAILURE_MODES_DIR"
    _check_target "$file" "$FAILURE_MODES_DIR"

    if [ -f "$file" ]; then
        if [ -z "$force" ]; then
            die "failure-mode '$slug' already exists at $file — this script does not merge; hand-edit the file directly to add/revise content (every real update to these records has been made this way), or re-run with --force to OVERWRITE THE ENTIRE FILE (destroys all existing content — only for an intentional full rewrite)."
        fi
        printf 'log-record: --force set — overwriting existing %s (prior content will be discarded)\n' "$file" >&2
    fi

    # >=3-occurrence promotion gate: count "pattern":"<slug>" (bare, no fm.
    # prefix) in the jsonl.  Skip the gate when updating an existing record or
    # when --skip-gate is passed (a FACE nested under an existing parent does
    # not need its own occurrence threshold).
    if [ ! -f "$file" ] && [ -z "$skip_gate" ] && [ -z "$face_of" ]; then
        local count=0
        if [ -f "$MISTAKES_JSONL" ]; then
            count="$(grep -cF "\"pattern\":\"${slug}\"" "$MISTAKES_JSONL" || true)"
        fi
        [ "$count" -ge 3 ] || die "failure-mode '$slug' has $count occurrence(s) in $MISTAKES_JSONL; need >=3 to create a record (pass --skip-gate to override)"
    fi

    [ -n "$mistake" ] || mistake="[pending]"
    [ -n "$correct" ] || correct="$rule"

    {
        printf -- '---\n'
        printf 'id: %s\n' "$id"
        printf 'kind: failure-mode\n'
        printf 'date: %s\n' "$date"
        printf 'keywords: %s\n' "$keywords"
        # rule is a single quoted sentence — the whole rule, on one line.
        printf 'rule: %s\n' "$(jq -nc --arg r "$rule" '$r')"
        if [ -n "$face_of" ]; then
            printf 'face_of: %s\n' "$face_of"
        fi
        if [ -n "$links_scenario" ] || [ -n "$links_criterion" ]; then
            printf 'links:\n'
            [ -n "$links_scenario" ]  && printf '  scenario: %s\n' "$links_scenario"
            [ -n "$links_criterion" ] && printf '  criterion: %s\n' "$links_criterion"
        else
            printf 'links: {}\n'
        fi
        [ -n "$mega" ] && printf 'mega: %s\n' "$mega"
        printf 'verification: pending\n'
        printf 'status: %s\n' "$status"
        # OPTIONAL, and OMITTED when empty — see cmd_decision.
        [ -n "$project" ] && printf 'project: %s\n' "$project"
        printf -- '---\n'
        printf '# %s\n\n' "$slug"
        printf '## Mistake\n\n%s\n\n' "$mistake"
        printf '## Correct\n\n%s\n' "$correct"
    } > "$file"

    printf 'log-record: wrote %s\n' "$file" >&2
}

# ===========================================================================
# dispatch
# ===========================================================================
[ $# -ge 1 ] || die "usage: log-record.sh <mistake|decision|solution|failure-mode> [flags]"
kind="$1"; shift
case "$kind" in
    mistake)      cmd_mistake "$@" ;;
    decision)     cmd_decision "$@" ;;
    solution)     cmd_solution "$@" ;;
    failure-mode) cmd_failure_mode "$@" ;;
    *) die "unknown kind: $kind (expected mistake|decision|solution|failure-mode)" ;;
esac
