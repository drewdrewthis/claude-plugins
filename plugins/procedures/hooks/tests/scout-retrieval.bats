#!/usr/bin/env bats
# The scout's retrieval contract: query-records.sh is its SOLE retrieval
# surface, batch reads go through --cat, and a record it can reach by hand but
# not by query is reported as a bug rather than routed around.
#
# These are prose assertions on an agent prompt, which is the only place the
# contract can live — the harness reads the markdown, not a config. They pin
# the load-bearing clauses, not the wording around them.
#
# Run: bats hooks/tests/scout-retrieval.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  REPO="$PLUGIN/../.."
  AGENT="$PLUGIN/agents/procedure-scout.md"
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
  SCRIPT="$PLUGIN/scripts/query-records.sh"
  # shellcheck source=../../scripts/lib/frontmatter.sh
  source "$PLUGIN/scripts/lib/frontmatter.sh"
}

fm_key() { fm_value "$(frontmatter_block "$1")" "$2"; }

# ---------- #34.2 query-records.sh is the sole retrieval surface ----------

@test "the scout body carries no free-form recursive grep fallback" {
  # `grep -rn '^keywords:' .../references/procedures/` was the documented
  # escape hatch when keyword search missed. It is exactly the silent
  # workaround that hides a keywords/matcher bug, and it reads a store subset
  # the query already covers.
  # Scoped to RUNNABLE lines (fenced bash blocks): a prohibition has to be able
  # to name the command it forbids, and a file-wide pattern would forbid the
  # Boundaries from saying "never use grep -r here".
  local offenders
  offenders="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && /grep -[a-zA-Z]*r/ { print FILENAME ":" FNR ": " $0 }
  ' "$AGENT")"
  [ -z "$offenders" ] || { echo "recursive grep fallback still in the scout:"; echo "$offenders"; false; }
}

@test "the scout body does not send the scout to find(1) for retrieval" {
  # Fence-scoped for the same reason the grep check above is: a file-wide
  # pattern also matches PROSE that names the command. `^[[:space:]]*find `
  # matched any line opening with the English word "find", so a future
  # Boundaries line like "find the governing record first" would fail the suite
  # with no defect present. What is forbidden is find(1) as a command the scout
  # RUNS, which is what a fenced bash block means.
  local offenders
  offenders="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && /(^|[^[:alnum:]_.\/-])find[[:space:]]/ { print FNR ": " $0 }
  ' "$AGENT")"
  [ -z "$offenders" ] || { echo "find(1) retrieval still in the scout:"; echo "$offenders"; false; }
}

@test "the scout body carries no raw awk batch-read recipe" {
  # Superseded by --cat. Left in place it is a second retrieval surface, and
  # the one that can read outside the record stores.
  run grep -n "FNR==1" "$AGENT"
  [ "$status" -ne 0 ] || { echo "raw awk batch-read still in the scout: $output"; false; }
}

@test "the scout reads selected records with --cat" {
  # Scoped to fenced bash blocks, so this pins --cat as a command the scout
  # RUNS. A bare file-wide grep would also be satisfied by a Boundaries line
  # merely mentioning --cat, or by prose that forbids it.
  local uses
  uses="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && /--cat/     { print FNR ": " $0 }
  ' "$AGENT")"
  [ -n "$uses" ] || { echo "no runnable --cat invocation in the scout body"; false; }
}

@test "every command block in the scout body invokes query-records.sh" {
  # The whole point of the issue: one retrieval surface. Any bash line in the
  # prompt that runs something else is a second one.
  # Fences are indented inside the numbered steps, so the pattern must not be
  # anchored hard to column 0 — anchoring it there is how this assertion passes
  # while reading nothing.
  local offenders blocks
  # `|| true`: bats runs test bodies under errexit and grep exits 1 on no
  # match, so without this the assignment aborts the test BEFORE the vacuity
  # guard below can print — the diagnostic could never fire.
  blocks="$(grep -cE '^[[:space:]]*```bash' "$AGENT" || true)"
  [ "$blocks" -ge 1 ] || { echo "no bash blocks found — assertion would pass vacuously"; false; }
  offenders="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && $0 ~ /[^[:space:]]/ && $0 !~ /query-records\.sh/ && $0 !~ /^[[:space:]]*#/ { print FILENAME ":" FNR ": " $0 }
  ' "$AGENT")"
  [ -z "$offenders" ] || { echo "non-query-records command in the scout prompt:"; echo "$offenders"; false; }
}

@test "the scout's tool grant does not reopen the retrieval surface it forbids" {
  # The frontmatter is where retrieval is actually enforced; the Boundaries are
  # only prose. Granting Read/Grep/Glob while forbidding their use for retrieval
  # left the second surface open at the layer that decides. Bash stays — the
  # scout runs query-records.sh and the digest replay through it.
  local tools
  tools="$(fm_key "$AGENT" tools)"
  [ -n "$tools" ] || { echo "no tools: key in the scout frontmatter"; false; }
  [[ "$tools" == *Bash* ]] || { echo "scout cannot run query-records.sh without Bash: $tools"; false; }
  for forbidden in Read Grep Glob; do
    [[ "$tools" != *"$forbidden"* ]] \
      || { echo "tools: grants $forbidden, which the Boundaries forbid for retrieval: $tools"; false; }
  done
}

@test "the scout's boundaries still scope reading to the discovered store list" {
  # Pre-existing guard (store-list-drift.bats) restated here as a diff-preserve
  # check: the retrieval rewrite must not have dropped it.
  grep -qF -- '--list-stores' "$AGENT"
}

# ---------- #34.3 an unreachable-but-real record is a bug signal ----------

@test "the scout is told to report a record it can reach but not query as a bug" {
  grep -qiE 'keywords .*(wrong|bug)|matcher .*(wrong|bug)|bug (signal|in the)' "$AGENT"
}

@test "the scout is forbidden from silently routing around a query miss" {
  # POSITIONALLY anchored, not two independent whole-file greps. The earlier
  # version checked "an unreachable clause exists" and "a prohibition exists"
  # separately, and passed with the prohibition DELETED — because an unrelated
  # rule elsewhere in the file ("never fall back to a raw grep over
  # mistakes.jsonl") satisfied the prohibition pattern on its own. Proven by
  # mutation; the window is what makes this test able to fail.
  local anchor window
  anchor="$(grep -inE 'unreachable|reach(able)? by hand|exists but' "$AGENT" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || { echo "no unreachable-record clause to anchor the prohibition to"; false; }
  window="$(sed -n "${anchor},$((anchor + 12))p" "$AGENT")"
  grep -qiE '(never|do not|not) .{0,40}(silently|work around|route around|fall back)' <<< "$window" \
    || { echo "no prohibition within 12 lines of the unreachable-record clause at line $anchor"; false; }
}

@test "the output shape has somewhere to put the unreachable-record finding" {
  # A finding with no slot in the report shape is a finding that never gets
  # emitted.
  grep -qiE 'UNREACHABLE|RETRIEVAL' "$AGENT"
}

# ---------- the tool and the prompt agree ----------

@test "the --full truncation notice points at --cat, not a raw awk recipe" {
  # The notice is the one place the SCRIPT tells a caller how to read the rest.
  # If it still hands out an awk one-liner, the prompt and the tool disagree
  # and the scout has a sanctioned way back out of the record stores.
  # Scoped to the notice STRING, not the whole file — print_full's own
  # implementation legitimately uses awk.
  local notice
  # `|| true` for the same errexit reason as the bash-block count above.
  notice="$(grep -n '(--full: dumped' "$SCRIPT" || true)"
  [ -n "$notice" ] || { echo "truncation notice not found — assertion would pass vacuously"; false; }
  [[ "$notice" == *"--cat"* ]] || { echo "notice does not point at --cat: $notice"; false; }
  [[ "$notice" != *"awk"* ]] || { echo "notice still advertises a raw awk batch-read: $notice"; false; }
}

@test "the skill routes batch-reads through query-records.sh, without restating the flag list" {
  # Say-each-thing-once: the AGENT owns the flag list and the prohibition (its
  # Boundaries); the skill points at the one tool. Two copies of the flag list
  # drifted apart the moment they existed.
  grep -qiE 'batch-read.*(go|goes) through|through it' "$SKILL"
  grep -qF 'query-records.sh' "$SKILL"
  run grep -c -- '--cat' "$SKILL"
  [ "$output" = "0" ] || { echo "skill restates the agent's flag list"; false; }
}

# ---------- #22 AC-4: every declaring agent, not just the scout ----------

@test "AC-4: every agent declaring model: that a skill forks is pinned by that skill" {
  # Generalises the procedures-only check in gate-skill-model.bats across every
  # plugin: enumerate the declaring agents (the issue's own sweep,
  # `grep -l '^model:' plugins/*/agents/*.md`), then require the fork skill
  # that dispatches each one to re-declare the same tier — because the fork
  # path reads the SKILL's model, never the agent's.
  local declaring checked=0
  declaring="$(grep -l '^model:' "$REPO"/plugins/*/agents/*.md 2>/dev/null || true)"
  [ -n "$declaring" ] || { echo "no agent declares model: — the sweep found nothing to check"; false; }

  local a agent_name agent_model s skill_model
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    agent_name="$(basename "$a" .md)"
    agent_model="$(fm_key "$a" model)"
    for s in "$REPO"/plugins/*/skills/*/SKILL.md; do
      [ "$(fm_key "$s" agent)" = "$agent_name" ] || continue
      [ "$(fm_key "$s" context)" = "fork" ] || continue
      skill_model="$(fm_key "$s" model)"
      [ "$skill_model" = "$agent_model" ] || {
        echo "$s forks $agent_name but pins '$skill_model' against the agent's '$agent_model'"
        false
      }
      checked=$((checked + 1))
    done
  done <<< "$declaring"

  [ "$checked" -ge 2 ] || { echo "expected at least the two gate forks, checked $checked"; false; }
}

# ---------- #22 AC-6: the inheritance is design, and is recorded as such ----------

@test "AC-6: the README records fork-model inheritance as documented harness design" {
  # The issue asks for a decision record rather than a 'fix' if the tier turns
  # out to be deliberately inherited. It is. This pins that the repo says so
  # AND cites where the harness documents it, so the next reader does not
  # refile it as a bug.
  local README="$REPO/README.md"
  grep -qiE 'documented (harness )?(design|behaviour|behavior)' "$README"
  grep -qF 'sub-agents' "$README"
}
