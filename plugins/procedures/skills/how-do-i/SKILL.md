---
name: how-do-i
description: "The gateway to everything the codex knows. Use when you (or the user) ask 'is there a procedure for X', 'how do we do X', AND — equally — whenever you are ABOUT TO PERFORM a documented operation, whether phrased as a question OR as a direct command ('tag the issue', 'label this PR', 'post to slack', 'cut a release', 'prune/launch/stop/migrate a session', 'run a fleet/orchardist op', 'drive boxd/remote'). An imperative 'do X' is still a trigger: learn the procedure BEFORE executing, not after. Never answer or execute github/slack/release/fleet/boxd operations from memory — those procedures and their paths change and your recall is stale. Corpus is the written RECORD stores (procedures, decisions, solutions, mistakes) — for what was actually said in past sessions use /recall."
user-invocable: true
context: fork
agent: procedure-scout
# PLUGIN ADAPTATION: fork skills ignore their agent's model: — must match
# agents/procedure-scout.md. See README "Fork-skill model pin".
model: sonnet
background: false
argument-hint: "<what you're trying to do>"
# PLUGIN ADAPTATION: "Fork-path agent prompt" (see README). A forked skill loads
# THIS file as the prompt and takes `agent:` as identity only, so the retrieval
# contract below lives here to bind at all. Whether this key reaches a fork is
# undocumented — it is a best-effort second layer; the prohibition in Boundaries
# is the control.
disallowed-tools: Read, Grep, Glob
---

The caller is about to act and needs to know how it is done here first.

GOAL:

$ARGUMENTS

Search the record stores, read every candidate in full, and return the proposal
in your output shape — what governs, the commands verbatim, the traps, and a
standing label on every source.

Tooling: the query interface is
`bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh"` — survey, recall,
and batch-read all go through it, and `--list-stores` prints the exact scan
surface (the `titw/` vendor store included, plus any extras named in
`QUERY_RECORDS_EXTRA_STORES`, space-separated root-relative paths; settings
`env` maps stack by scope, so projects can add stores). Your Boundaries carry
the rule about what that excludes.

Start warm. Before step 1, read what you already returned this session:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/session-digest-read.sh" --read "${CLAUDE_SESSION_ID}"
```

Empty output means this is the session's first pass — say nothing about it and
proceed cold.

Anything it prints is your own earlier digest. It answered a DIFFERENT goal, so
it tells you where to look first, never a search you can skip. Run your full
query pass regardless — what governs THIS goal is exactly what the earlier one
never needed. Then label each source in your proposal:

- **already established** — the digest above carried it; cite it without
  re-deriving.
- **newly found** — this search surfaced it.

If the goal is ambiguous, say which reading you took rather than picking one
silently.

# Retrieval loop

Let `QR` stand for `bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh"`
below. Every command in this section runs through it.

0. **Resolve the target repo — only when the goal is repo-scoped** (a PR, an
   issue, a branch, a workflow run). Take the FIRST source that answers:
   1. goal text — an explicit `owner/repo`, or a URL carrying one;
   2. held context, only where it concerns the CURRENT goal (the caller's brief
      for this task). A digest from an unrelated prior goal is search context,
      not a repo source;
   3. the working directory.
   Never silently assume cwd. State which source you used on the `REPO:` line.
   Costs no Bash call.

1. **Restate the goal in one line.** Name the reading you took if the ask is
   ambiguous. A wrong reading found here is cheap; found after the caller acts
   it is not.

2. **Open with `--recall`, in one Bash call with `--list-stores`.** `--recall`
   is a single multi-signal query over the failure stores — it is what replaces
   iterative probing, so it goes FIRST, not last. Send both at once:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --recall '<full term set from the goal>'
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --list-stores
   ```

   Give recall the *whole* term set from the goal in one pass — it is built for
   many signals at once, and splitting it into probes is the cost this ordering
   removes. Whitespace separates terms; keep phrases hyphenated (`pickup-loop`),
   never split them. Output is a `recall: N matched` count line, then the 20
   most recent hits (raise `--limit` only when the count says more exist and the
   overflow is plausibly on-goal). `--list-stores` prints the exact scan
   surface, one store per line — that is the store list step 3 must cover.
   ⚠ never fall back to a raw `grep` over `mistakes.jsonl` — unanchored
   `grep -i` matches inside paths and URLs; `--recall` matches only semantic
   field values, whole-word
   ⚠ if the count exceeds the hits you read, say so in STANDING NOTES — a cap
   is allowed, a SILENT one is not

3. **Probe the gaps recall left — every remaining store, in one Bash call.**
   Recall covers the failure stores; the procedure and decision stores it does
   not reach are a gap by construction, and so is any facet of the goal that
   came back with zero hits. Compare what recall returned against the
   `--list-stores` surface and close the difference:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --keyword "<term set>"
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --kind procedure --keyword "<term set>"
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --links-to <id-you-already-found>
   ```

   Gloss calls only (no `--full`). Expand synonyms — the caller's words rarely
   match the corpus's — and search the *capability* as well as the identifier:
   "the cache", not just the function name. `--links-to` on a record you already
   trust is the highest-yield follow-up: the corpus's own cross-references beat
   another synonym guess.
   ⚠ every store still gets surveyed — this step is reordered, not narrowed. A
   store you never queried is not a store recall covered
   ⚠ a term set that returns nothing is a RESULT — go to step 4b's miss rule,
   never to a tool outside this script

4. **Select, then batch-read — through the same script.** From recall's hits
   and every survey list, pick every plausibly relevant path — err inclusive, a
   gloss can undersell a record — and read them in ONE call:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/query-records.sh" --cat <path> <path> ...
   ```

   Paste the paths the survey printed, verbatim. `--cat` takes them exactly as
   printed, and also accepts a whole newline-separated list as one argument, so
   piping a survey's first column straight in works in any shell. It dedupes,
   accepts paths from as many surveys as you like, and is uncapped. Read to the
   end of each — an Investigation or Evolution section below the steps can
   supersede them; the output is full text, not a preview.

   Reserve `--full` for a narrow query only: `--id`, or a tight `--kind` +
   `--keyword` where the match list is already the read set. Never run `--full`
   on a broad first-pass keyword survey — it caps at 10 records with a
   truncation notice, and dumping before selecting wastes context on records a
   gloss would have excluded.
   ⚠ `--cat` refusing a path is the boundary working, not a reason to reach for
   `cat`

4b. **A record you can reach but cannot query is a BUG — report it.** If you
   learn a relevant record exists (a link from another record, a path in the
   caller's goal) that none of your queries returned, its `keywords` or the
   matcher is wrong. Read it with `--cat`, use it, and name it under
   `UNREACHABLE` in your output with the query that should have found it.
   ⚠ never silently work around a query miss — an unreported matcher bug
   misroutes every later caller, and a grep that "worked this time" is what
   keeps it invisible

5. **Return the proposal.** Nothing else — no preamble, no narration of your
   search. If steps 2-4 found nothing, emit only the `NOT FOUND` section and
   stop. A miss is a finished answer, not a reason to widen the search.

**Budget: a typical goal finishes in 3-4 Bash calls** — recall + `--list-stores`
together, the gap probes together, the `--cat` batch, and a second `--cat` if
step 4b turns one up. Put every query you already know you need into the same
Bash call rather than paying a round trip each; a step above that lists several
commands means one call, not several.
⚠ this is guidance, not a cap. Thoroughness wins ties: never skip a gap probe,
a store, or a follow-up read to come in under it. Going over is a cost; missing
a record the caller needed is a wrong answer.

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

TRAPS:
  - <what goes wrong> — <path> [standing]

STANDING NOTES:
  - <any source that is draft / single-instance / contradicted elsewhere>
  - <recall: N matched, 20 read>   # emit when step 4's count exceeds what you read

UNREACHABLE (retrieval bug): <path>
  - query that should have matched it: <the exact flags you ran>
  - suspect: <the record's `keywords`, or the matcher>

NOT FOUND: <what you searched for and did not find>
  -> improvise; draft the procedure once it works, via /create-new (kind: procedure)
```

Omit any section that is empty. An empty `TRAPS` is worth stating once — it
means nobody has recorded a failure here yet, which is itself information.

# Boundaries

- **`query-records.sh` is your ONLY retrieval tool** — surveying with
  `--keyword`/`--kind`/`--id`/`--links-to`/`--recall`, reading with
  `--cat`/`--full`. No `grep`, `find`, `ls`, `awk`, `cat`, `head`, or `Read` of
  a record. They read the same bytes, so this is not about capability: a search
  the script cannot express is a corpus bug (step 4b), and a private tool is how
  it stays unfixed.
- Never search outside the record stores plus `mistakes.jsonl`, under
  `${CODEX_ROOT:-$HOME/.claude}`. The store list is discovered, not memorized —
  `--list-stores` prints it. This scopes what you READ, not where your tools
  live: running `query-records.sh` is always in bounds. The wider repo, the
  working tree, and the web are not the answer surface.
- **Commands are quoted byte-for-byte.** Never paraphrase, reformat, re-flag, or
  "clean up" a command. A summarised invocation is a silent corruption.
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
  improvisation has actually worked, via `/create-new` (kind: procedure). A
  procedure written before it has succeeded once is a guess with a `proc.` id
  on it.
- Do not return the corpus. A proposal is a distillation with paths, not a paste
  of every doc you opened — the whole point is that the caller's context stays
  small.
