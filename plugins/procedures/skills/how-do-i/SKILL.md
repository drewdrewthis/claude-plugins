---
name: how-do-i
description: "The gateway to everything the codex knows. Use when you (or the user) ask 'is there a procedure for X', 'how do we do X', AND — equally — whenever you are ABOUT TO PERFORM a documented operation ('tag the issue', 'label this PR', 'cut a release', 'prune/launch/stop a session', 'drive boxd/fleet'). An imperative 'do X' is still a trigger: learn the procedure BEFORE executing. Invoke with TWO parts separated by '|': (1) GOAL — one concrete sentence stating what you are about to DO and where (repo/surface), not the question but the action; (2) TERMS — the full search vocabulary: every concept the answer might touch, each with 2–3 synonyms, corpus words included (proc, fm, evolve, squash), phrases hyphenated. The list must be COMPLETE because there is exactly one query. Never answer or execute github/slack/release/fleet/boxd operations from memory."
user-invocable: true
# PLUGIN ADAPTATION: upstream forks this skill; here it runs inline —
# no agent:/model:/background: keys. It shells to scripts/how-do-i.sh, whose
# claude -p children carry independent token budgets.
context: inline
argument-hint: "<goal — what you're about to do> | <terms — full search vocabulary>"
disallowed-tools: Read, Grep, Glob
---

The caller is about to act and has handed you a GOAL and a TERM LIST. You turn
them into one question, run the two-stage retrieval pipeline ONCE, and hand
back the grounded proposal it returns.

ARGUMENTS (split on the first '|'):

$ARGUMENTS

Tooling: the retrieval interface is

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/how-do-i.sh" --question '<GOAL> <TERM LIST> as one sentence'
```

⚠ Compose the question WITHOUT the `|` separator — that is an
argument-format convention between you and the caller, and a literal `|`
inside the value would be denied by the shape guard.

One script, both stages: stage 1 selects relevant records from a numbered
index (fast model), compile-records.sh assembles their full text, stage 2
writes the answer from that text alone (strong model). The answer arrives
cited to source paths, commands quoted byte-for-byte.

# Steps

0. **Parse the arguments.** Left of `|` is the GOAL; right is the TERM LIST.
   If either part is missing, say so in your output and work with what you
   have — expanding thin terms yourself from the goal.

1. **Build the question from what you already know.** Merge three inputs
   into ONE question string — the GOAL plus the merged term set:
   - the caller's TERM LIST (complete by contract — keep every term);
   - anything earlier turns this session proved about the corpus's
     vocabulary;
   - corrections the goal implies (an ambiguous term disambiguated by the
     goal's action).
   Keep phrases hyphenated (`pickup-loop`). This refinement happens BEFORE
   the call — there is no second call to fix a bad set. ⚠ the question string
   carries NO `|`: the shape guard denies pipes, so join GOAL and terms with
   plain whitespace.

2. **Run ONE Bash call** — the pipeline, and (when it applies) the justfile
   probe ride together:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/how-do-i.sh" --question '<GOAL + merged term set, no separators>'
   ```

3. **If the repo has `just` and a justfile**, append the probe to the SAME
   call:

   ```bash
   command -v just >/dev/null && just --dump --dump-format json | jq -r '.recipes | to_entries[] | "\(.key)\t\(.value.doc // "-")"'
   ```

   Recipes whose name or doc comment relates to the goal go under `RECIPES`.
   Soft-degrade silently when `just`/justfile are absent — never a retrieval
   miss, never a reason to widen the search.

4. **Return the pipeline's answer** — relay it verbatim (its citations and
   verbatim commands are the product), then append your RECIPES section. No
   preamble, no narration of the search. If the answer ends in `NOT FOUND`,
   emit that section with its `/update-records` line and stop — a miss is a
   finished answer, not a reason to run a second query.

**Budget: exactly ONE pipeline run, ever.** There is no retry, no widening,
no follow-up pull. If a record you know exists did not surface, report it
under `NOT FOUND` with the exact question you asked — reporting it is what
gets the index or the record's description fixed, and probing around it is
what keeps it broken.

# Standing

Label every source the answer cites. The corpus is self-authored — agents
write records and later agents cite them as authority — so provenance
travels with content:

| Label | Means |
|---|---|
| **tested** | A hook, lint, or bats suite enforces it — an `enforced_by:` field or a matching test file |
| **incident-backed** | Records a specific failure that happened, with the consequence named |
| **asserted** | Prose with neither — `status: draft`, a lone evolution entry, an unreferenced claim |

An `asserted` source is a lead, not a ruling. Say so in the same line you cite
it.

# Output

Relay the pipeline's answer (it keeps the GOAL / GOVERNS / COMMANDS /
TRAPS / STANDING NOTES / NOT FOUND shape), then add:

```
RECIPES (step 3 hits — preferred over reciting equivalent raw commands):
  $ just <name>   # <one-line doc comment>

STANDING (your labels on the cited paths):
  - <path> [tested|incident-backed|asserted]
```

Omit any section that is empty. An empty `TRAPS` is worth stating once — it
means nobody has recorded a failure here yet, which is itself information.

# Boundaries

- **One pipeline run is your ONLY retrieval act** — no second
  `how-do-i.sh` call, no direct build/compile invocations, and no `grep`,
  `find`, `ls`, `awk`, `cat`, `head`, or `Read` of a record. The stages see
  the whole corpus; hand-picking around them defeats the selection and
  hides its misses. The shape guard denies any other form — treat a denial
  as the contract working.
- Never search outside the record stores plus `mistakes.jsonl`, under
  `${CODEX_ROOT:-$HOME/.claude}`. The wider repo, the working tree, and the
  web are not the answer surface. Sole exception: the cwd-resolving
  justfile's `just --dump` read (step 3) sits alongside the stores, not
  inside them.
- **Commands are quoted byte-for-byte.** Never paraphrase, reformat, re-flag,
  or "clean up" a command. A summarised invocation is a silent corruption.
- **Every claim carries its source path**, or it is unverifiable and worthless.
- **Read-only.** No edit, no create, no commit, nothing that changes state.
  ⚠ `Bash` can still mutate — `gh`, `git`, `rm` remain reachable, so read-only
  is a rule you keep, not one the harness keeps for you.
- Never act on the goal, invent a procedure not on disk, omit a trap because it
  looks unlikely, or flatten a contradiction between two records — report both
  and say they disagree.
- **Absence is a finding, with an instruction.** "Nothing governs this" is a
  real answer: tell the caller to improvise and to draft the procedure once the
  improvisation has actually worked, via `/update-records procedure`. A
  procedure written before it has succeeded once is a guess with a `proc.` id
  on it.
- Do not return the corpus. A proposal is a distillation with paths, not a paste
  of every doc you opened — the whole point is that the caller's context stays
  small.
