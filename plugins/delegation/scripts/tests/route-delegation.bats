#!/usr/bin/env bats
# Tests for scripts/route-delegation.sh — the delegation routing table as a script.
#
# Every test points CLAUDE_AGENTS_DIR at a mktemp fixture roster, so the real
# ~/.claude/agents tree is NEVER read: the script's whole contract is "the model
# comes from the roster on disk", and a test that read the live roster would pass
# or fail on whatever the host happens to have minted today.
#
# Coverage map — the four exit codes and what distinguishes them:
#   0  a matched route, with the model read from FIXTURE frontmatter
#   1  usage errors: a kind that needs a subflag and did not get one; unknown kind
#   2  no specialist fits (--kind other), AND the agent-less host (empty/missing
#      roster) — the PLUGIN ADAPTATION that keeps a fresh tenant off the drift path
#   3  genuine roster drift: the matched agent is missing while OTHER agents
#      exist, or its file carries no `model:` key
#   --list dumps every route with live models
#
# Run: bats scripts/tests/route-delegation.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../route-delegation.sh"
  FIX="$(mktemp -d)"
  AGENTS="$FIX/agents"
  mkdir -p "$AGENTS"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# Write a roster agent file. $1 = agent name, $2 = model (omit for no model: key).
write_agent() {
  local name="$1" model="${2:-}"
  {
    echo "---"
    echo "name: $name"
    echo "description: \"Fixture agent for the routing tests.\""
    [ -n "$model" ] && echo "model: $model"
    echo "---"
    echo ""
    echo "# Role"
    echo ""
    echo "Fixture."
    echo ""
    echo "# Boundaries"
    echo ""
    echo "Nothing."
  } > "$AGENTS/$name.md"
}

# Mint every agent the routing table references, so a test that is not about
# drift cannot trip over an unrelated missing file.
write_full_roster() {
  write_agent fast-coder haiku
  write_agent coder sonnet
  write_agent advanced-coder opus
  write_agent researcher sonnet
  write_agent scribe sonnet
  write_agent planner opus
  write_agent principles-reviewer sonnet
  write_agent hygiene-reviewer sonnet
  write_agent security-reviewer sonnet
  write_agent test-reviewer sonnet
  write_agent proof-reviewer opus
  write_agent ac-reviewer opus
  write_agent devils-advocate opus
  write_agent codex-auditor sonnet
}

# Run the router against the fixture roster.
route() {
  run env CLAUDE_AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@"
}

# ---- exit 0: a matched route reads its model from the roster ----

@test "code + standard routes to coder with the model read from fixture frontmatter" {
  write_full_roster
  route --kind code --difficulty standard
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: coder"* ]]
  [[ "$output" == *"model: sonnet"* ]]

  # The model is READ, not hardcoded: retune the fixture, the answer follows.
  write_agent coder opus
  route --kind code --difficulty standard
  [ "$status" -eq 0 ]
  [[ "$output" == *"model: opus"* ]]
}

# ---- exit 1: usage errors ----

@test "--kind code without --difficulty is a usage error" {
  write_full_roster
  route --kind code
  [ "$status" -eq 1 ]
  [[ "$output" == *"--kind code requires --difficulty"* ]]
}

@test "an unknown --kind is a usage error" {
  write_full_roster
  route --kind interpretive-dance
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown --kind: interpretive-dance"* ]]
}

# ---- exit 2: no specialist fits, and the agent-less host ----

@test "--kind other exits 2 with a self-extension rule naming /create-new-sub-agent" {
  write_full_roster
  route --kind other
  [ "$status" -eq 2 ]
  [[ "$output" == *"No specialist fits this task shape."* ]]
  [[ "$output" == *"/create-new-sub-agent"* ]]
  # Host-specific codex wiring must not leak into a plugin-shipped message.
  [[ "$output" != *"guard-general-purpose.sh"* ]]
}

@test "an EMPTY roster dir exits 2 with the self-extension rule, not roster drift" {
  # The agent-less tenant: a host that has minted no agents has not drifted.
  route --kind code --difficulty standard
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agent roster found"* ]]
  [[ "$output" == *"/create-new-sub-agent"* ]]
}

@test "a MISSING roster dir exits 2 with the self-extension rule" {
  rm -rf "$AGENTS"
  route --kind search
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agent roster found"* ]]
  [[ "$output" == *"/create-new-sub-agent"* ]]
}

# ---- exit 3: genuine roster drift ----

@test "a matched agent missing while OTHER agents exist is roster drift" {
  # This is the distinction the empty-roster guard must not swallow: agents are
  # present, so the ABSENCE of this one is a real inconsistency to fix.
  write_full_roster
  rm "$AGENTS/scribe.md"
  route --kind prose
  [ "$status" -eq 3 ]
  [[ "$output" == *"roster drift"* ]]
  [[ "$output" == *"scribe.md"* ]]
}

@test "an agent file with no model: frontmatter is roster drift" {
  write_full_roster
  write_agent planner            # no model: key
  route --kind plan
  [ "$status" -eq 3 ]
  [[ "$output" == *"roster drift"* ]]
  [[ "$output" == *"no 'model:' frontmatter key"* ]]
}

# ---- --list ----

@test "--list dumps every route with live models" {
  write_full_roster
  route --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"code:mechanical"* ]]
  [[ "$output" == *"fast-coder"* ]]
  [[ "$output" == *"[haiku]"* ]]
  [[ "$output" == *"review:proof"* ]]
  [[ "$output" == *"proof-reviewer"* ]]
  [[ "$output" == *"audit:"* ]]
  [[ "$output" == *"codex-auditor"* ]]
  [[ "$output" == *"other/no-match"* ]]
  [[ "$output" == *"/create-new-sub-agent"* ]]
}

@test "--list against an agent-less host exits 2 rather than reporting drift" {
  route --list
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agent roster found"* ]]
}
