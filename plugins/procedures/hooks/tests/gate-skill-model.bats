#!/usr/bin/env bats
# PLUGIN ADAPTATION: this suite has no upstream counterpart — it guards a
# plugin-only divergence (the `model:` pin the gate SKILL.md files carry), so it
# exists in this repo alone by construction. See README.md, "Fork-skill model
# pin", for the mechanism and the measurement.
#
# Run: bats hooks/tests/gate-skill-model.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  # shellcheck source=../../scripts/lib/frontmatter.sh
  source "$PLUGIN/scripts/lib/frontmatter.sh"
  SKILLS="$PLUGIN/skills"
  AGENTS="$PLUGIN/agents"
}

# Value of <key> in <file>'s frontmatter, via the shared reader so a fix there
# reaches this suite too.
fm_key() {
  fm_value "$(frontmatter_block "$1")" "$2"
}

@test "every context:fork skill pins the same model its agent declares" {
  # One assertion for the whole invariant: a fork skill must pin a model, and
  # that pin must agree with the agent's own — so a tier change cannot land in
  # one file alone. The counter guards against the glob failing to expand: with
  # no nullglob, "$SKILLS"/*/SKILL.md iterates once over the literal pattern
  # when the dir is wrong, every check falls through, and the test would
  # otherwise pass having verified nothing.
  local checked=0
  for f in "$SKILLS"/*/SKILL.md; do
    [ "$(fm_key "$f" context)" = "fork" ] || continue
    local a sm am
    a="$(fm_key "$f" agent)"
    sm="$(fm_key "$f" model)"
    am="$(fm_key "$AGENTS/$a.md" model)"
    [ -n "$sm" ] || { echo "$f declares context:fork with no model: pin"; false; }
    [ "$sm" = "$am" ] || { echo "$f pins '$sm' but agents/$a.md declares '$am'"; false; }
    checked=$((checked + 1))
  done
  [ "$checked" -ge 2 ] \
    || { echo "expected >=2 context:fork skills, checked $checked — glob or path is wrong"; false; }
}

@test "both gate skills are among the context:fork skills checked above" {
  # Pins WHICH skills the loop covers, so deleting a skill's `context: fork`
  # cannot quietly drop it from the invariant while the count still passes.
  [ "$(fm_key "$SKILLS/how-do-i/SKILL.md" context)" = "fork" ]
  [ "$(fm_key "$SKILLS/am-i-done/SKILL.md" context)" = "fork" ]
}

@test "the agent-side model declaration is still present (belt and braces)" {
  # Honoured on the Agent(subagent_type:) path even though the fork path ignores
  # it — removing it would break direct dispatch of these agents.
  # Asserted per file: `grep -c pat f1 f2` exits 0 when EITHER file matches, so a
  # single grep over both would pass with one agent's declaration deleted.
  [ -n "$(fm_key "$AGENTS/procedure-scout.md" model)" ]
  [ -n "$(fm_key "$AGENTS/work-reviewer.md" model)" ]
}
