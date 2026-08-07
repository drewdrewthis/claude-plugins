#!/usr/bin/env bats
# Tests that both gate skills pin their fork's model in SKILL.md frontmatter.
#
# A `context: fork` skill does NOT inherit the model from its `agent:`'s own
# frontmatter — it inherits the PARENT SESSION's model. Measured: dispatched
# from an opus session, procedure-scout ran claude-opus-5 despite declaring
# `model: sonnet` in agents/procedure-scout.md. The agent-side declaration is
# only honoured on the Agent(subagent_type:) path.
#
# These assert the declaration is PRESENT. They cannot prove the harness
# honours it — that needs a live dispatch, see the PR's verification section.
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
  run bash -c "grep -c '^model: sonnet' '$BATS_TEST_DIRNAME/../../agents/procedure-scout.md' '$BATS_TEST_DIRNAME/../../agents/work-reviewer.md'"
  [ "$status" -eq 0 ]
}
