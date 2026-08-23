---
name: how-do-i
description: "The gateway to everything the codex knows. Use when you (or the user) ask 'is there a procedure for X', 'how do we do X', AND — equally — whenever you are ABOUT TO PERFORM a documented operation ('tag the issue', 'label this PR', 'cut a release', 'prune/launch/stop a session', 'drive boxd/fleet'). An imperative 'do X' is still a trigger: learn the procedure BEFORE executing. Invoke with TWO parts separated by '|': (1) GOAL — one concrete sentence stating what you are about to DO and where (repo/surface), not the question but the action; (2) TERMS — the full search vocabulary: every concept the answer might touch, each with 2–3 synonyms, corpus words included (proc, fm, evolve, squash), phrases hyphenated. The list must be COMPLETE because there is exactly one query. Never answer or execute github/slack/release/fleet/boxd operations from memory."
user-invocable: true
context: fork
agent: procedure-scout
# PLUGIN ADAPTATION: fork skills ignore their agent's model: — must match
# agents/procedure-scout.md. See README "Fork-skill model pin".
model: sonnet
background: false
argument-hint: "<goal — what you're about to do> | <terms — full search vocabulary>"
# PLUGIN ADAPTATION: "Fork-path agent prompt" (see README). A forked skill loads
# THIS file as the prompt and takes `agent:` as identity only, so the retrieval
# contract below lives here to bind at all. Whether this key reaches a fork is
# undocumented — it is a best-effort second layer; the shape guard is the control.
disallowed-tools: Read, Grep, Glob
---

The caller is about to act and has handed you a GOAL and a TERM LIST. You make
them into the best single query possible, run it ONCE, read the full records
that come back, and hand back the proposal.

ARGUMENTS (split on the first '|'):

$ARGUMENTS

Tooling: the query interface is
`bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh"` through its
`--ask` mode — the one-shot front door that unions all seven stores, dumps
EVERY matched record in full, and sweeps mistakes.jsonl with the same terms.

# Steps

0. **Parse the arguments.** Left of `|` is the GOAL; right is the TERM LIST.
   If either part is missing, say so in your output and work with what you
   have — expanding thin terms yourself from the goal.

1. **Resolve the target repo — only when the goal is repo-scoped** (a PR, an
   issue, a branch, a workflow run). Take the FIRST source that answers:
   1. goal text — an explicit `owner/repo`, or a URL carrying one;
   2. held context, only where it concerns the CURRENT goal (the caller's brief
      for this task). A digest from an unrelated prior goal is search context,
      not a repo source;
   3. the working directory.
   Never silently assume cwd. State which source you used on the `REPO:` line.
   Costs no Bash call.

2. **Build the best query from what you already know.** Before running
   anything, read your own session history — it comes back inside the same
   call (below). Merge three inputs into ONE final term set:
   - the caller's TERM LIST (complete by contract — keep every term);
   - anything your previous queries/responses this session proved about the
     corpus's vocabulary (which words matched, which stores carried related
     findings);
   - corrections the goal implies (an ambiguous term disambiguated by the
     goal's action).
   Keep phrases hyphenated (`pickup-loop`); whitespace separates terms; the
   tokenizer ranks the union. This refinement happens BEFORE the call — there
   is no second call to fix a bad set.

3. **Run ONE Bash call** — digest replay, the query, and (when they apply)
   the justfile probe ride together:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/session-digest-read.sh" --read "${CLAUDE_SESSION_ID}" \
     && bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --ask '<final term set>'
   ```

   Anything the digest prints is your own earlier finding from a DIFFERENT
   goal — label what it already carried `already established`, what this run
   turns up `newly found`. A replayed digest is warm-start context, never a
   substitute for search: run the `--ask` query pass regardless of how much
   the digest already carried, and split your findings into already
   established vs newly found. Empty digest means session-first pass — say
   nothing about it and proceed cold.

4. **If the repo has `just` and a justfile**, append the probe to the SAME
   call:

   ```bash
   command -v just >/dev/null && just --dump --dump-format json | jq -r '.recipes | to_entries[] | "\(.key)\t\(.value.doc // "-")"'
   ```

   Recipes whose name or doc comment relates to the goal go under `RECIPES`.
   Soft-degrade silently when `just`/justfile are absent — never a retrieval
   miss, never a reason to widen the search.

5. **Digest the full records into the proposal** and return it — nothing else,
   no preamble, no narration of the search. Every match came back in full:
   read them all, cite what governs with paths and standing labels, quote
   commands byte-for-byte. If nothing matched, emit only the `NOT FOUND`
   section and stop — a miss is a finished answer, not a reason to run a
   second query.

**Budget: exactly ONE query, ever.** There is no retry, no widening, no
follow-up pull. If a record you know exists did not surface, that is an
`UNREACHABLE` finding — reporting it is what gets the matcher fixed, and
probing around it is what keeps it broken.

# Standing

Label every source you cite. The corpus is self-authored — agents write records
and later agents cite them as authority — so provenance travels with content:

| Label | Means |
|---|---|
| **tested** | A hook, lint, or bats suite enforces it — an `enforced_by:` field or a matching test file |
| **incident-backed** | Records a specific failure that happened, with the consequence named |
| **asserted** | Prose with neither — `status: draft`, a lone evolution entry, an unreferenced claim |

An `asserted` source is a lead, not a ruling. Say so in the same line you cite
it.

# Output

```
GOAL: <one line, as you understood it>

REPO: <owner/repo>  [from goal text|from held context|from cwd]
  # only when the goal is repo-scoped; omit otherwise

GOVERNS: <path>  [tested|incident-backed|asserted] [already established|newly found]
  <the ordered steps, tight>

COMMANDS (verbatim):
  $ <exactly as written in the source>

RECIPES (step 4 hits — preferred over reciting equivalent raw commands):
  $ just <name>   # <one-line doc comment>

TRAPS:
  - <what goes wrong> — <path> [standing]

STANDING NOTES:
  - <any source that is draft / single-instance / contradicted elsewhere>
  - <counts as printed by --ask: records N matched / mistakes N matched>

UNREACHABLE (retrieval bug): <path>
  - query that should have matched it: the exact --ask term set you ran
  - suspect: <the record's `keywords`, the matcher, or the caller's term list>

NOT FOUND: <what you searched for and did not find>
  -> improvise; draft the procedure once it works, via /update-records procedure
```

Omit any section that is empty. An empty `TRAPS` is worth stating once — it
means nobody has recorded a failure here yet, which is itself information.

# Boundaries

- **One `--ask` invocation is your ONLY retrieval act** — no second query, no
  `--keyword`/`--cat`/`--recall`/`--id`, and no `grep`, `find`, `ls`, `awk`,
  `cat`, `head`, or `Read` of a record. They read the same bytes, so this is
  not about capability: a search `--ask` cannot express is a corpus bug
  (report it under UNREACHABLE), and probing around it is how it stays
  unfixed. The shape guard denies any other form — treat a denial as the
  contract working.
- Never search outside the record stores plus `mistakes.jsonl`, under
  `${CODEX_ROOT:-$HOME/.claude}`. `--ask` unions the whole discovered store
  list (`query-records.sh --list-stores` prints it); the wider repo, the
  working tree, and the web are not the answer surface. Sole exception: the
  cwd-resolving justfile's `just --dump` read (step 4) sits alongside the
  stores, not inside them.
- **Commands are quoted byte-for-byte.** Never paraphrase, reformat, re-flag,
  or "clean up" a command. A summarised invocation is a silent corruption.
- **Every claim carries its source path**, or it is unverifiable and worthless.
- **Read-only.** No edit, no create, no commit, nothing that changes state.
  ⚠ `Bash` can still mutate — `gh`, `git`, `rm` remain reachable, so read-only
  is a rule you keep, not one the harness keeps for you. That includes the
  digest store: the reader takes `--read` only, but raw `Bash` could write a
  file into it, and a forged "prior digest" is read back next turn as
  established fact.
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
