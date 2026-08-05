#!/usr/bin/env bash
# route-delegation.sh — the delegation routing table, as a script.
#
# Per references/solutions/2026-05-28-script-not-template.md ("script, not
# template"): the agent<->model mapping used to live as hand-written prose in
# references/procedures/codex-meta/delegation-routing/PROCEDURE.md. A table
# duplicated in prose drifts from the real roster (agents/*.md model:
# frontmatter is the actual source of truth for what model an agent runs).
# This script IS the routing table now; the procedure just points here.
#
# The model for each matched agent is read LIVE from agents/<name>.md
# frontmatter, not hardcoded — retuning the roster (e.g. bumping `coder` to
# a different tier) propagates automatically. If an agent file the tree
# expects is missing, that is roster drift and this script errors loudly
# rather than silently reporting a stale model.
#
# Usage:
#   route-delegation.sh --kind code --difficulty mechanical|standard|hard
#   route-delegation.sh --kind search
#   route-delegation.sh --kind prose
#   route-delegation.sh --kind plan
#   route-delegation.sh --kind review --focus principles|hygiene|security|test|proof
#   route-delegation.sh --kind ac
#   route-delegation.sh --kind stress-test
#   route-delegation.sh --kind debug
#   route-delegation.sh --kind audit
#   route-delegation.sh --kind other       # no specialist fits -> exit 2
#   route-delegation.sh --list             # dump the full routing table
#   route-delegation.sh -h | --help
#
# Exit codes: 0 matched, 1 usage error, 2 no-match (--kind other) or no roster
# on this host at all, 3 roster drift (matched agent's file/model missing from
# disk while the host DOES have other agents).

set -uo pipefail

# PLUGIN ADAPTATION: the roster is the HOST's, not the plugin's. Upstream the
# script lives inside the codex repo and reads its sibling agents/ dir; installed
# as a plugin that path would point at the plugin's own directory, which ships no
# agents by design (machinery ships, the roster is the host's). Defaults to the
# host codex, overridable for tests and for hosts that keep agents elsewhere.
AGENTS_DIR="${CLAUDE_AGENTS_DIR:-${CODEX_ROOT:-$HOME/.claude}/agents}"

# ---- the decision tree: one row per "kind[:subflag]|agent|rationale" ----
# This array IS the routing table. --list derives its dump from it (plus a
# live model lookup); the procedure doc no longer duplicates it.
ROUTES=(
  "code:mechanical|fast-coder|Mechanical, fully-specified, NO judgment — file rewrites from an exact spec, find/replace, one-line appends, boilerplate, INDEX/ref updates."
  "code:standard|coder|Standard implementation, test writing."
  "code:hard|advanced-coder|Judgment-bearing TDD — incomplete/absent tests, co-designing contracts across interacting modules, root-causing unknown failures."
  "search:|researcher|Read-only codebase exploration / \"go find X\" / \"how does X work\" / multi-file search."
  "prose:|scribe|Durable non-code prose — docs, references, memory, ADRs, research reports, READMEs, doc-comments."
  "plan:|planner|Multi-file design/impl planning — step plan + tradeoffs + draft ACs for ac-reviewer."
  "review:principles|principles-reviewer|SRP, readability, extensibility, simplicity — is this well-designed code?"
  "review:hygiene|hygiene-reviewer|Reuse, existing patterns, dead code, bloat, idioms, boy scout rule."
  "review:security|security-reviewer|PII exposure, hardcoded secrets, sensitive data leaks."
  "review:test|test-reviewer|Test pyramid placement, coverage, naming, quality, efficiency."
  "review:proof|proof-reviewer|Does each AC tick map to real, load-bearing evidence, not a self-report?"
  "ac:|ac-reviewer|AC completeness/coverage against the stated goal, then sharpness grading."
  "stress-test:|devils-advocate|Adversarial stress-test of an architecture/plan/proposal before committing."
  "debug:|advanced-coder|Multi-file reasoning / complex debugging whose mechanism is unknown at dispatch — alias of 'code --difficulty hard'. Supersedes the legacy 'deep-research' row in the old table: no 'deep-research' Agent subagent_type exists in the current roster (it is a research skill, not an agent), so this collapses to advanced-coder."
  "audit:|codex-auditor|Read-only codex-corpus audit — template/destination/single-responsibility conformance across references/plans/agents/skills, drafts a reorg plan, never edits."
)

usage() {
  cat <<'EOF'
route-delegation.sh — pick the right specialist for a job (the routing table, as a script)

  route-delegation.sh --kind code --difficulty mechanical|standard|hard
  route-delegation.sh --kind search
  route-delegation.sh --kind prose
  route-delegation.sh --kind plan
  route-delegation.sh --kind review --focus principles|hygiene|security|test|proof
  route-delegation.sh --kind ac
  route-delegation.sh --kind stress-test
  route-delegation.sh --kind debug
  route-delegation.sh --kind audit
  route-delegation.sh --kind other       # no specialist fits -> prints self-extension rule, exit 2
  route-delegation.sh --list             # dump the full routing table
  route-delegation.sh -h | --help

The decision tree (task shape -> specialist):
  code + mechanical   -> fast-coder        (Haiku)   fully-specified, no judgment
  code + standard     -> coder             (Sonnet)  standard impl / test writing
  code + hard         -> advanced-coder    (Opus)    judgment-bearing TDD, unknown-mechanism debugging
  debug               -> advanced-coder    (Opus)    alias of code+hard; supersedes stale 'deep-research' row
  search              -> researcher        (Sonnet)  read-only codebase exploration / multi-file search
  prose               -> scribe            (Sonnet)  durable non-code prose: docs, ADRs, memory, READMEs
  plan                -> planner           (Opus)    multi-file design/impl planning + draft ACs
  review + principles -> principles-reviewer (Sonnet/Opus per agent) SRP/readability/simplicity
  review + hygiene    -> hygiene-reviewer  (Sonnet/Opus per agent) reuse/dead-code/idioms
  review + security   -> security-reviewer (Sonnet/Opus per agent) PII/secrets/leaks
  review + test       -> test-reviewer     (Sonnet/Opus per agent) test pyramid/coverage/quality
  review + proof      -> proof-reviewer    (Sonnet/Opus per agent) AC-tick evidence audit
  ac                  -> ac-reviewer       (Opus)    AC completeness + sharpness
  stress-test         -> devils-advocate   (Opus)    adversarial plan/design stress-test
  audit               -> codex-auditor     (Sonnet)  read-only codex-corpus conformance audit, drafts reorg plan
  other / no match    -> mint the agent via /create-new-sub-agent, then reload;
                         general-purpose is the last resort on both axes

Model shown is read live from <roster>/<name>.md frontmatter, not hardcoded.
The roster is the HOST's: $CLAUDE_AGENTS_DIR, else $CODEX_ROOT/agents, else
~/.claude/agents. A host with no roster at all exits 2 with the self-extension
rule — that is a host that has minted no agents, not roster drift.
Exit codes: 0 matched, 1 usage error, 2 no-match / no roster, 3 roster drift
(matched agent's file/model missing while other agents exist).
EOF
}

# Read the `model:` frontmatter key live from agents/<name>.md. Errors loudly
# (exit 3) if the file or key is missing — that is roster drift, not a
# routing decision this script should paper over.
agent_model() {
  local name="$1"
  local file="$AGENTS_DIR/$name.md"
  local model
  if [ ! -f "$file" ]; then
    echo "route-delegation: roster drift — expected agent file missing: agents/$name.md" >&2
    exit 3
  fi
  model="$(awk '
    NR==1 && $0=="---" { infm=1; next }
    infm==1 && $0=="---" { exit }
    infm==1 && $0 ~ /^model:[[:space:]]*/ { sub(/^model:[[:space:]]*/,""); print; exit }
  ' "$file")"
  if [ -z "$model" ]; then
    echo "route-delegation: roster drift — agents/$name.md has no 'model:' frontmatter key" >&2
    exit 3
  fi
  printf '%s' "$model"
}

# Look up a route by "kind:subflag" key against ROUTES. Prints "agent|rationale" or empty.
lookup_route() {
  local key="$1" row rkey
  for row in "${ROUTES[@]}"; do
    rkey="${row%%|*}"
    if [ "$rkey" = "$key" ]; then
      printf '%s' "${row#*|}"
      return 0
    fi
  done
  return 1
}

# PLUGIN ADAPTATION: host-neutral self-extension wording. Upstream names the
# codex's own files (agents/<name>.md, references/model-selection.md,
# hooks/guard-general-purpose.sh + settings.json) — none of which a plugin host
# is guaranteed to have. The rule is the same; the handle is the skill this
# plugin ships.
print_self_extension_rule() {
  cat <<'EOF'
No specialist fits this task shape.

Self-extension rule: mint the agent via /create-new-sub-agent — it writes a
right-sized model + tools allowlist into your agent roster — then reload so the
session sees it, and dispatch the new agent by name.

general-purpose is the LAST RESORT on both axes (coding and non-coding), not a
default. Reaching for it quietly on mechanical or prose work burns Opus on tasks
Haiku/Sonnet would do faster and cheaper.
EOF
}

# PLUGIN ADAPTATION: graceful agent-less degradation. A host with no roster at
# all — a fresh tenant, a bare container — is not roster drift; it has simply
# never minted an agent. Answering exit 3 there would report a corruption that
# does not exist. The lookup path below assumes a roster; this guard runs first.
require_roster() {
  if [ -d "$AGENTS_DIR" ] && compgen -G "$AGENTS_DIR/*.md" > /dev/null 2>&1; then
    return 0
  fi
  echo "route-delegation: no agent roster found at $AGENTS_DIR — this host has minted no agents yet." >&2
  print_self_extension_rule
  exit 2
}

do_list() {
  local row key agent rationale model
  require_roster
  for row in "${ROUTES[@]}"; do
    key="${row%%|*}"
    agent="${row#*|}"; agent="${agent%%|*}"
    rationale="${row#*|*|}"
    model="$(agent_model "$agent")" || exit $?
    printf '%-20s -> %-20s [%s]\n    %s\n' "$key" "$agent" "$model" "$rationale"
  done
  # PLUGIN ADAPTATION: host-neutral wording, matching print_self_extension_rule.
  printf '%-20s -> %s\n' "other/no-match" "mint via /create-new-sub-agent, then reload; general-purpose = last resort"
}

# ---- parse args ----
KIND=""
DIFFICULTY=""
FOCUS=""

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 1
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)       KIND="${2:-}"; shift 2 ;;
    --difficulty) DIFFICULTY="${2:-}"; shift 2 ;;
    --focus)      FOCUS="${2:-}"; shift 2 ;;
    --list)       do_list; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "route-delegation: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$KIND" ]; then
  echo "route-delegation: --kind is required" >&2
  usage >&2
  exit 1
fi

if [ "$KIND" = "other" ]; then
  print_self_extension_rule
  exit 2
fi

# Build the lookup key per kind.
case "$KIND" in
  code)
    case "$DIFFICULTY" in
      mechanical|standard|hard) : ;;
      "")
        echo "route-delegation: --kind code requires --difficulty mechanical|standard|hard" >&2
        usage >&2
        exit 1
        ;;
      *)
        echo "route-delegation: unknown --difficulty: $DIFFICULTY (want mechanical|standard|hard)" >&2
        usage >&2
        exit 1
        ;;
    esac
    LOOKUP_KEY="code:$DIFFICULTY"
    ;;
  review)
    case "$FOCUS" in
      principles|hygiene|security|test|proof) : ;;
      "")
        echo "route-delegation: --kind review requires --focus principles|hygiene|security|test|proof" >&2
        usage >&2
        exit 1
        ;;
      *)
        echo "route-delegation: unknown --focus: $FOCUS (want principles|hygiene|security|test|proof)" >&2
        usage >&2
        exit 1
        ;;
    esac
    LOOKUP_KEY="review:$FOCUS"
    ;;
  search|prose|plan|ac|stress-test|debug|audit)
    LOOKUP_KEY="$KIND:"
    ;;
  *)
    echo "route-delegation: unknown --kind: $KIND" >&2
    usage >&2
    exit 1
    ;;
esac

# PLUGIN ADAPTATION: guard the roster BEFORE the lookup path, so an agent-less
# host answers "mint one" (exit 2) instead of drift (exit 3). Placed after flag
# validation so a usage error still reports as a usage error.
require_roster

MATCH="$(lookup_route "$LOOKUP_KEY")" || {
  echo "route-delegation: internal error — no route defined for key '$LOOKUP_KEY'" >&2
  exit 1
}

AGENT="${MATCH%%|*}"
RATIONALE="${MATCH#*|}"
MODEL="$(agent_model "$AGENT")" || exit $?

printf 'agent: %s\n' "$AGENT"
printf 'model: %s\n' "$MODEL"
printf 'why:   %s\n' "$RATIONALE"
exit 0
