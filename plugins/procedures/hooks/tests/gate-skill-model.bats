#!/usr/bin/env bats
# PLUGIN ADAPTATION: this suite has no upstream counterpart — it guards a
# plugin-only divergence (the `model:` pin the gate SKILL.md files carry), so it
# exists in this repo alone by construction.
#
# Tests that both gate skills pin their fork's model in SKILL.md frontmatter.
#
# A `context: fork` skill does NOT inherit the model from its `agent:`'s own
# frontmatter — it inherits the PARENT SESSION's model. Measured: dispatched
# from an opus session, procedure-scout ran claude-opus-5 despite declaring
# `model: sonnet` in agents/procedure-scout.md. The agent-side declaration is
# only honoured on the Agent(subagent_type:) path.
#
# These assert the declaration is PRESENT. Proving the harness HONOURS it needs
# a live dispatch; that was measured separately (an opus-parent fork moved to
# claude-haiku-4-5 when the skill declared `model: haiku`, with the parent's own
# turns staying on opus) and is recorded on the PR, not here.
#
# Run: bats hooks/tests/gate-skill-model.bats

setup() {
  SKILLS="$BATS_TEST_DIRNAME/../../skills"
}

# frontmatter_key <file> <key> — value of <key> inside the first --- block only,
# so a body mention can never satisfy the assertion.
frontmatter_key() {
  awk -v k="$2" '/^---$/{n++; next} n==1 && $1==k":"{ $1=""; sub(/^ /,""); print; exit }' "$1"
}

@test "how-do-i pins its fork to sonnet in SKILL.md frontmatter" {
  run frontmatter_key "$SKILLS/how-do-i/SKILL.md" model
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "am-i-done pins its fork to sonnet in SKILL.md frontmatter" {
  run frontmatter_key "$SKILLS/am-i-done/SKILL.md" model
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "every context:fork skill declares a model (none may inherit the session tier)" {
  # Guards the next fork skill added, not just today's two.
  local missing=""
  for f in "$SKILLS"/*/SKILL.md; do
    if [ "$(frontmatter_key "$f" context)" = "fork" ] && [ -z "$(frontmatter_key "$f" model)" ]; then
      missing="$missing $(basename "$(dirname "$f")")"
    fi
  done
  [ -z "$missing" ] || { echo "fork skills with no model: pin:$missing"; false; }
}

@test "the agent-side model declaration is still present (belt and braces)" {
  # Honoured on the Agent(subagent_type:) path even though the fork path ignores
  # it — removing it would break direct dispatch of these agents.
  # Asserted per file: `grep -c pat f1 f2` exits 0 when EITHER file matches, so a
  # single grep over both would pass with one agent's declaration deleted.
  local agents="$BATS_TEST_DIRNAME/../../agents"
  [ "$(frontmatter_key "$agents/procedure-scout.md" model)" = "sonnet" ]
  [ "$(frontmatter_key "$agents/work-reviewer.md" model)" = "sonnet" ]
}
