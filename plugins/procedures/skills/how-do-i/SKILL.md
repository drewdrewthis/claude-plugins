---
name: how-do-i
description: "DEPRECATED — use /what-do-i-know instead. Kept only as a functional alias for a session that still names Skill(procedures:how-do-i) (an old habit, or a re-armed enable_how_do_i_gate) — same pipeline, same contract, full write-up at skills/what-do-i-know/SKILL.md."
user-invocable: true
# PLUGIN ADAPTATION: upstream forks this skill; here it runs inline —
# no agent:/model:/background: keys. It shells to scripts/how-do-i.sh, whose
# claude -p children carry independent token budgets.
context: inline
argument-hint: "<goal — what you're about to do> | <terms — full search vocabulary>"
disallowed-tools: Read, Grep, Glob
---

**DEPRECATED — use `/what-do-i-know` instead.** This alias exists so a
session that names `Skill(procedures:how-do-i)` (an old habit, or a re-armed
`enable_how_do_i_gate`) still gets a correct answer. Same pipeline, same
contract — see `skills/what-do-i-know/SKILL.md` for the full write-up.

ARGUMENTS (split on the first '|'):

$ARGUMENTS

# Steps

0. Parse GOAL (left of `|`) and TERM LIST (right of `|`).
1. Build ONE question string: GOAL + the merged term set, no `|` inside it
   (the shape guard denies pipes).
2. Run ONE Bash call:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/how-do-i.sh" --question '<GOAL + merged term set, no separators>'
   ```

   If the repo has `just` and a justfile, append the probe to the SAME call:

   ```bash
   command -v just >/dev/null && just --dump --dump-format json | jq -r '.recipes | to_entries[] | "\(.key)\t\(.value.doc // "-")"'
   ```

3. Relay the pipeline's answer verbatim — citations and commands byte-for-byte,
   no paraphrase. Append a `RECIPES` line per justfile hit, if any.

**Budget: exactly ONE pipeline run, ever.** No retry, no second query, no
direct `grep`/`find`/`ls`/`Read` of a record — the shape guard denies any
other form. A record that did not surface is a `NOT FOUND` to report, not a
reason to widen the search.
