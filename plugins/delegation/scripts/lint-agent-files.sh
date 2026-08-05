#!/usr/bin/env bash
# lint-agent-files.sh — structural lint for agent definition files
# (agents/*.md and each persistent agent's agents/<name>/CLAUDE.md).
#
# Enforces the agent-file template: every agent file must declare who it is
# (frontmatter), what it does (a `Role` section) and what it must not do (a
# `Boundaries` section), and must carry no time-bound or issue-bound text.
# Dates and issue refs are incident narration — they rot, and an agent file is
# a standing instruction, not a changelog.
#
# HARD rules (exit 1 on any violation):
#   R1 FRONTMATTER — a `---` block on line 1 carrying `name:` and `description:`
#   R2 ROLE        — a heading whose text is exactly `Role` (any level)
#   R3 BOUNDARIES  — a heading whose text is exactly `Boundaries` (any level)
#   R4 NO-DATE     — no ISO date (20YY-MM-DD) anywhere in the file
#   R5 NO-ISSUEREF — no issue/PR reference (#NNN) anywhere in the file.
#                    Ordinary markdown anchor links — `[step](#3-verify)` — are
#                    NOT issue refs and do not fire: the template tells agent
#                    files to point at procedures, and deep-linking a numbered
#                    heading is the normal way to do that. `](#123)`, whose
#                    fragment is purely digits, still fires.
#
# WARN rules (never fail the run):
#   W1 SIZE        — line budget by class: a `-reviewer` agent targets 80 lines,
#                    every other agent targets 150. Line count is a smell
#                    signal, not a correctness gate. Class comes from the
#                    frontmatter `name:` when that is a bare identifier, and
#                    from the FILENAME otherwise — an absent `name:`, a folded
#                    scalar (`name: >-`) or a quoted multi-word value must not
#                    silently downgrade a reviewer to the 150-line budget.
#   W2 MODEL       — frontmatter has no `model:` key.
#
# LEGACY rules over agents/.lint-legacy (the grandfather list):
#   L1 STALE       — a listed path that does not exist → HARD FAIL.
#   L2 RATCHET     — a listed file that now passes every hard rule → HARD FAIL,
#                    demanding its line be deleted. This is what makes the list
#                    SHRINK-ONLY: once a file conforms it can never rejoin.
#   A listed file that violates a hard rule → WARN, does not fail the run.
#
# agents/EVOLUTION.md is excluded (a log, not an agent definition). Everything
# else nested under agents/ is excluded too — notes, hooks, .claude wiring —
# with the single exception of agents/<name>/CLAUDE.md, which IS a role file.
#
# Usage:
#   scripts/lint-agent-files.sh                 # lint every agent role file
#   scripts/lint-agent-files.sh <file> [file..] # lint only the named files
#                                               # (repo-relative paths; the L1
#                                               #  stale + L2 ratchet checks
#                                               #  over the whole .lint-legacy
#                                               #  list still run)
#
# Targeted mode FAILS CLOSED. A named target that does not exist, or that is
# not a lintable agent file, is an ERROR — not a silent skip. Every run also
# prints a `linted N file(s)` accounting line (same precedent as
# scripts/lint-procedure-edges.sh), so "it printed nothing" can never be
# mistaken for "it checked something and found nothing".
#
# CODEX_SNAPSHOT=1 downgrades every hard failure to a printed WARN and exits 0
# — same contract as passes 5-10 / authoring_fail() in git-hooks/pre-commit:
# the offending file is already on disk, so blocking an unattended backup
# cannot un-write it.
#
# Pure bash/grep/awk; no network, no LLM. Called by git-hooks/pre-commit
# (pass 10) and runnable standalone.

set -uo pipefail

# Data root = the HOST codex, not the plugin dir. Overridable via
# LINT_AGENT_FILES_ROOT for testing against fixture agent trees.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PLUGIN ADAPTATION: data-root default. Upstream the script lives inside the
# codex repo, so its parent dir IS the tree to lint; installed as a plugin that
# would lint the plugin's own (agent-less) directory. Same $CODEX_ROOT chaining
# as every other script in this repo.
ROOT="${LINT_AGENT_FILES_ROOT:-${CODEX_ROOT:-$HOME/.claude}}"
cd "$ROOT" || exit 1

AGENTS_DIR="agents"
LEGACY_FILE="$AGENTS_DIR/.lint-legacy"
SNAPSHOT="${CODEX_SNAPSHOT:-0}"

# SSOT frontmatter readers — frontmatter_block() and fm_value(). Shared with
# scripts/lint-frontmatter.sh, which used to carry byte-identical copies.
# shellcheck source=scripts/lib/frontmatter.sh
source "$SCRIPT_DIR/lib/frontmatter.sh"

REVIEWER_BUDGET=80
DEFAULT_BUDGET=150

FAIL=0
# Set when a per-file R-rule (R1-R5) actually fired, so the failure epilogue
# only recites the R-rule contract when an R-rule is what broke. An L1/L2
# legacy-list failure has nothing to do with frontmatter or headings.
R_FIRED=0
# How many files the per-file pass actually inspected (the accounting line).
LINTED=0

# A hard violation. Under CODEX_SNAPSHOT it prints as a WARN and does not fail.
err() {
    if [ "$SNAPSHOT" = "1" ]; then
        echo "⚠ agent-lint WARNING [codex-snapshot]: $*" >&2
        return 0
    fi
    echo "❌ agent-lint: $*" >&2
    FAIL=1
}

warn() { echo "⚠ agent-lint WARNING: $*" >&2; }

# ---- helpers ---------------------------------------------------------------
# frontmatter_block() and fm_value() come from scripts/lib/frontmatter.sh
# (sourced above).

# True for a lintable agent definition. TWO shapes, both role definitions:
#   agents/<name>.md        — flat: an agent with no home directory.
#   agents/<name>/CLAUDE.md — a PERSISTENT agent, whose home IS its session cwd
#                             and whose role therefore loads from that cwd's
#                             CLAUDE.md rather than from a flat file.
#
# The second shape is covered because a persistent agent's role file is still a
# role file. When the orchardist moved from agents/orchardist.md into
# agents/orchardist/CLAUDE.md it silently left this gate — the fleet's most
# important role definition became the one nobody checked. A gate keyed on
# LOCATION rather than on ROLE loses its subject the moment the layout changes.
#
# Anything else nested under agents/ (notes, hooks, .claude wiring) is NOT a
# role definition and stays excluded.
is_agent_file() {
    case "$1" in
        "$AGENTS_DIR"/*/CLAUDE.md)
            # Exactly one path segment between agents/ and CLAUDE.md.
            _rest="${1#"$AGENTS_DIR"/}"
            case "${_rest%/CLAUDE.md}" in
                */*) return 1 ;;
            esac
            return 0
            ;;
        "$AGENTS_DIR"/*/*) return 1 ;;
        "$AGENTS_DIR"/*.md) ;;
        *) return 1 ;;
    esac
    [ "$(basename "$1")" = "EVOLUTION.md" ] && return 1
    return 0
}

# Every agent role file worth linting, sorted: the flat agents/*.md plus each
# persistent agent's agents/<name>/CLAUDE.md.
agent_files() {
    [ -d "$AGENTS_DIR" ] || return 0
    {
        find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'EVOLUTION.md'
        find "$AGENTS_DIR" -mindepth 2 -maxdepth 2 -type f -name 'CLAUDE.md'
    } | sort
}

DATE_RE='20[0-9]{2}-[0-9]{2}-[0-9]{2}'
ISSUEREF_RE='#[0-9]+'

# Print $1 with markdown anchor links removed, so R5 sees only real issue refs.
#
# `[step](#3-verify)` is a link into a numbered heading, not a reference to
# issue 3 — and AGENT_TEMPLATE.md actively tells agent files to point at
# procedures, so deep-linking numbered headings is the expected shape. Before
# this, the only exits for a NEW (un-grandfathered) file were rewording the
# link or `--no-verify`.
#
# Only the `](#<fragment>)` shape with a fragment that is NOT purely digits is
# removed. `](#123)`, `(#123)` and a bare `#123` all survive and still fire —
# the rule is not weakened, only aimed.
strip_md_anchors() {
    sed -E 's/\]\(#[^)]*[^0-9)][^)]*\)//g' "$1" 2>/dev/null
}

# Print $1 with date-prefixed RECORD FILENAMES removed, so R4 sees only real
# dates in prose.
#
# Codex records are date-prefixed by convention — `references/solutions/
# 2026-07-28-four-lanes-exhaust-github-graphql-quota.md`. That date is part of
# a PATH, not a dated correction, and R4 exists to stop agent files narrating
# "CORRECTED 2026-07-13", not to stop them citing a record. Without this,
# R4 makes the repo's own naming convention unciteable from an agent file:
# the correct fix (point at the record instead of inlining its content) is
# exactly what the rule would forbid. Same shape as strip_md_anchors above.
strip_record_paths() {
    sed -E 's#[A-Za-z0-9_./~-]*/20[0-9]{2}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+##g' "$1" 2>/dev/null
}

# Emit one `RULE<TAB>message` line per HARD-rule violation in $1. Silent when
# the file conforms. Callers decide whether that is a FAIL or a WARN.
#
# This is the FORMATTER. Anything that needs a yes/no answer must use
# hard_violation_count() below, never the emptiness of this function's stdout.
hard_violations() {
    local f="$1" block hit ln
    if [ "$(head -1 "$f")" != "---" ]; then
        printf 'R1\tmissing frontmatter block (first line is not "---")\n'
    else
        block="$(frontmatter_block "$f")"
        printf '%s\n' "$block" | grep -qE '^name:' \
            || printf 'R1\tfrontmatter missing required key "name:"\n'
        printf '%s\n' "$block" | grep -qE '^description:' \
            || printf 'R1\tfrontmatter missing required key "description:"\n'
    fi

    grep -qE '^#{1,6}[[:space:]]+Role[[:space:]]*$' "$f" \
        || printf 'R2\tno Role section (needs a heading whose text is exactly "Role")\n'

    grep -qE '^#{1,6}[[:space:]]+Boundaries[[:space:]]*$' "$f" \
        || printf 'R3\tno Boundaries section (needs a heading whose text is exactly "Boundaries")\n'

    # The excerpt is `cut -c1-70` from column 1, so it very often cuts the
    # offending token away entirely — the message named a rule and showed a
    # fragment that did not contain the thing that fired. Both R4 and R5 now
    # quote the MATCHED TOKEN first; the excerpt is context, not evidence.
    hit="$(strip_record_paths "$f" | grep -nEm1 "$DATE_RE" || true)"
    if [ -n "$hit" ]; then
        ln="${hit%%:*}"
        printf 'R4\tISO date "%s" at line %s (agent files carry no dates): %s\n' \
            "$(printf '%s' "${hit#*:}" | grep -oE "$DATE_RE" | head -1)" \
            "$ln" "$(printf '%s' "${hit#*:}" | cut -c1-70)"
    fi

    # R5 runs over an anchor-stripped view of the file so ordinary markdown
    # deep-links do not read as issue refs. Line numbering is unaffected —
    # strip_md_anchors only removes substrings — so the excerpt is still pulled
    # from the ORIGINAL line.
    hit="$(strip_md_anchors "$f" | grep -nEm1 "$ISSUEREF_RE" || true)"
    if [ -n "$hit" ]; then
        ln="${hit%%:*}"
        printf 'R5\tissue/PR reference "%s" at line %s (agent files carry no issue refs): %s\n' \
            "$(printf '%s' "${hit#*:}" | grep -oE "$ISSUEREF_RE" | head -1)" \
            "$ln" "$(sed -n "${ln}p" "$f" 2>/dev/null | cut -c1-70)"
    fi
}

# Count of HARD-rule violations in $1 — the RATCHET'S PREDICATE, deliberately
# a separate contract from the formatter above.
#
# L2 used to ask `[ -z "$(hard_violations "$entry")" ]`, which made every line
# hard_violations ever prints load-bearing: one future stray stdout line (a
# debug echo, a new advisory) would silently declare a still-violating file
# "graduated" and hard-fail the repo. This counts only well-formed
# `R<n><TAB><message>` records, so unrelated output cannot flip the verdict.
hard_violation_count() {
    hard_violations "$1" | awk -F'\t' '$1 ~ /^R[0-9]+$/ && NF >= 2 { n++ } END { print n+0 }'
}

# Emit the WARN-rule findings for $1 (W1 size budget, W2 missing model:).
warn_rules() {
    local f="$1" block name lines budget klass
    block=""
    [ "$(head -1 "$f")" = "---" ] && block="$(frontmatter_block "$f")"

    # Size-budget CLASS. Deriving it from `name:` alone is permissive on every
    # malformed frontmatter: an absent `name:`, a folded scalar (`name: >-`),
    # or a quoted multi-word value all failed the `*-reviewer` match and fell
    # through to the 150-line default, silently costing a reviewer file its
    # 80-line budget with no output at all.
    #
    # So: use `name:` only when it is a bare identifier. Anything else tells us
    # nothing about the class, and we fall back to the FILENAME, which the
    # roster convention keeps in sync with the name.
    name="$(fm_value "$block" name)"
    name="${name%"${name##*[![:space:]]}"}"   # trim trailing whitespace only
    name="${name//\"/}"
    name="${name//\'/}"
    case "$name" in
        ''|*[!A-Za-z0-9._-]*) name="" ;;      # not a bare identifier → unusable
    esac

    case "${name:-$(basename "$f" .md)}" in
        *-reviewer) budget="$REVIEWER_BUDGET"; klass="reviewer" ;;
        *)          budget="$DEFAULT_BUDGET";  klass="agent" ;;
    esac

    # An unreadable file yields an empty `lines`, which used to reach `[ -gt ]`
    # as `[: : integer expression expected` — shell noise where a finding
    # belonged. Say so instead of emitting a broken comparison.
    lines="$(awk 'END{print NR}' "$f" 2>/dev/null)"
    if [ -z "$lines" ]; then
        warn "$f: W1: cannot read the file — line count unavailable, size budget NOT checked"
    elif [ "$lines" -gt "$budget" ]; then
        warn "$f: W1: $lines lines over the ${budget}-line ${klass} budget — tighten the prose. Do NOT move the agent's own method into a procedure and point at it: an agent carries its method inline (AGENT_TEMPLATE, 'An agent carries its own method')"
    fi

    printf '%s\n' "$block" | grep -qE '^model:' \
        || warn "$f: W2: frontmatter has no 'model:' key — the tier is left to chance"
}

# ---- read the grandfather list ---------------------------------------------
# One repo-relative path per line; `#` starts a comment; blanks ignored.
declare -A LEGACY=()
LEGACY_ORDER=()
if [ -f "$LEGACY_FILE" ]; then
    line=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        if [ -z "${LEGACY[$line]+x}" ]; then
            LEGACY["$line"]=1
            LEGACY_ORDER+=("$line")
        fi
    done < "$LEGACY_FILE"
fi

# ---- decide which files to actually lint ------------------------------------
# TARGETED=1 means every path came from the CALLER and is therefore a claim
# that the path is a lintable agent file. A claim that turns out to be false is
# an error. In whole-tree mode the paths come from agent_files(), which cannot
# produce one, so the same check is unreachable there.
if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
    TARGETED=1
else
    mapfile -t TARGETS < <(agent_files)
    TARGETED=0
fi

# ---- per-file pass ----------------------------------------------------------
for f in "${TARGETS[@]:-}"; do
    [ -n "$f" ] || continue

    # FAIL CLOSED on a named target we cannot lint. These were `|| continue`
    # — two silent skips with nothing counting what got linted, so
    # `lint-agent-files.sh agents/typo.md` printed nothing and exited 0. A
    # typo'd path, a renamed file or a caller passing the wrong subset all
    # read as "checked, clean".
    if ! is_agent_file "$f"; then
        if [ "$TARGETED" = "1" ]; then
            err "$f: not a lintable agent file (expected agents/<name>.md, not nested, not EVOLUTION.md)"
        fi
        continue
    fi
    if [ ! -f "$f" ]; then
        if [ "$TARGETED" = "1" ]; then
            err "$f: named target does not exist"
        fi
        continue
    fi

    LINTED=$((LINTED + 1))

    while IFS= read -r v; do
        [ -n "$v" ] || continue
        rule="${v%%$'\t'*}"
        msg="${v#*$'\t'}"
        if [ -n "${LEGACY[$f]+x}" ]; then
            warn "$f: $rule: $msg [grandfathered in $LEGACY_FILE]"
        else
            err "$f: $rule: $msg"
            R_FIRED=1
        fi
    done < <(hard_violations "$f")

    warn_rules "$f"
done

# The accounting line — printed on EVERY run, pass or fail, so silence is never
# mistakable for a clean bill of health. Precedent: scripts/lint-procedure-edges.sh
# prints `corpus=N nodes, edges_checked=N` unconditionally.
echo "agent-lint: linted $LINTED file(s)"

# ---- legacy-list integrity (always runs, even in targeted mode) -------------
# The list is SHRINK-ONLY. Both checks below are what enforce that, so they are
# deliberately independent of which files were passed in: a targeted run must
# not be able to hide a stale or graduated entry.
for entry in "${LEGACY_ORDER[@]:-}"; do
    [ -n "$entry" ] || continue
    if [ ! -f "$entry" ]; then
        err "$entry: L1: listed in $LEGACY_FILE but the file does not exist — delete the line (the list is shrink-only)"
        continue
    fi
    # PREDICATE, not formatter output: hard_violation_count() counts well-formed
    # R-rule records only, so an unrelated line on hard_violations' stdout can
    # never make a still-violating file look graduated.
    if [ "$(hard_violation_count "$entry")" -eq 0 ]; then
        err "$entry: L2: now passes every hard rule — delete its line from $LEGACY_FILE (entries are deleted, never added)"
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "" >&2
    # Only recite the R-rule contract when an R-rule is what failed. An L1/L2
    # legacy-list failure printed this too, telling a reader to go fix
    # frontmatter and headings that were never the problem.
    if [ "$R_FIRED" -eq 1 ]; then
        echo "agent-lint failed. Every agents/*.md needs name:/description: frontmatter," >&2
        echo "a Role heading and a Boundaries heading, and carries no dates and no issue" >&2
        echo "refs. Fix the files above, or (NOT recommended) bypass with:" >&2
    else
        echo "agent-lint failed. Fix the findings above, or (NOT recommended) bypass with:" >&2
    fi
    echo "  git commit --no-verify" >&2
    exit 1
fi
exit 0
