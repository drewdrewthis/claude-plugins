# ADR-001: The procedural-knowledge system

**Status:** Accepted. Consolidates the design decisions behind the `procedures`
plugin (originally made incrementally in a private codex repo; restated here
without the history).

## The problem

Agents repeat mistakes, improvise operations that already have a known-good
procedure, and claim work done without verification. Written guidance alone
does not fix this: advisory text injected into a session arrives as log
output, not a command, and does not bind behavior. Knowledge must be (a)
stored so it can be found, (b) consulted before acting, and (c) grown from
real outcomes — and each of those needs a mechanism, not a convention.

## Taxonomy: procedure, skill, hook

- **A procedure is a prose script.** The atomic unit is the *document*
  (`PROCEDURE.md`), not an index entry — a procedure is read whole, top to
  bottom, and its frontmatter is its discovery surface. There are no
  maintained index files; digests are compiled per-query by the scout.
- **A skill is a gateway with context.** It is the invocation handle
  (`/how-do-i`, `/log`, `/am-i-done`): thin, user/agent-invocable, and it may
  carry context or dispatch a subagent (`context: fork` + `agent:`). Executor
  skills are not demotable to procedure docs — the handle is the point.
- **A hook is deterministic enforcement.** Anything that must *always*
  happen (gates, frontmatter schema) is a script wired to a lifecycle event,
  never a request in prose.

## Per-turn invariant gates

Two invariants hold on every main-agent turn, enforced by blocking hooks:

1. **`/how-do-i` before acting** — no mutating tool call until the
   procedure-scout has been consulted this turn (`how-do-i-gate.sh`,
   PreToolUse, all tools).
2. **`/am-i-done` before stopping** — any turn that called tools gets one
   cold-read review of its am-i-done report before the turn may end
   (`am-i-done-gate.sh`, Stop — asks at most once; when there is genuinely
   nothing to review, stop honestly rather than fabricating work).

Design rules the gates follow:

- **Gate on act, not on look.** Reads of the procedure corpus and read-only
  discovery commands are allowlisted — a good `/how-do-i` query cannot be
  formed before you know what the turn is about. `Skill` and `Agent` calls
  are always allowed: they *are* the compliance path, and denying them
  deadlocks the session.
- **Subagents are never gated.** A delegated specialist runs its own
  contract, and the gated skills themselves dispatch subagents.
- **Turn state is marker files, not JSON.** One file per satisfied invariant
  per session (`$TURN_STATE_DIR/<sid>.<key>`), reset each UserPromptSubmit,
  recorded by a PostToolUse(Skill) hook. Setting a flag is an atomic `touch`;
  there is no read-modify-write to race.
- **Turn state is not derived from the transcript, though it could be.** Hook
  payloads carry `transcript_path`, and "did Skill(how-do-i) run after the
  last user message" is a parse away — but the how-do-i gate fires on every
  tool call, and parsing an unbounded transcript per call loses to an O(1)
  marker `stat`; the transcript is Claude Code's internal, unversioned
  format, so deriving every gate from it couples the hot path to a schema
  that shifts across releases; and a transcript-derived gate cannot make the
  unwired-vs-unsatisfied distinction the `.turn` marker exists for. The one
  place transcript truth is genuinely needed — "did this turn call any
  tool," at Stop — is the one place it is read (`turn-activity.sh`), once
  per turn, wrapped in fail-open.
- **Fail open, and record blind failures.** Missing jq, unreadable state, an
  unwired reset hook — all release the gate. A gate that blocks on its own
  bug bricks the session. Every *blind* fail-open (as opposed to a legitimate
  release) is appended to a jsonl log so silent degradation is visible.

## Records

- Every record carries the **six-key frontmatter** (`id`, `kind`, `date`,
  `keywords` non-empty, `links`, `status`) — enforced by lint + hook. The
  frontmatter is the index; `query-records.sh` is the one PULL interface over
  all stores. There are no materialized views and no index files: the
  procedure-scout compiles a digest per query, so nothing can go stale
  between a record and its copy.
- **Two naming namespaces, deliberately.** Host procedure records live as
  directories (`references/procedures/<area>/<name>/PROCEDURE.md` plus a
  sibling `EVOLUTION.md`); the reference and template files a plugin *ships*
  use the flat `<name>.procedure.md` / `<name>.template.md` form. A plugin file
  is read-only payload with no evolution log of its own, so it needs no
  directory.
- **Mistakes are events, failure-modes are records.** Each mistake appends
  one structured jsonl row at correction time; a recurring pattern is
  promoted to a durable failure-mode record only at ≥3 occurrences (the
  script enforces the bar).

## Evolution

- **Every procedure directory carries an `EVOLUTION.md`**: one dated line per
  material change, newest first, never rewritten. It is the memory of why
  the procedure reads the way it does.
- **Draft, then promote.** A procedure is written only after the work has
  succeeded once (a procedure written first is a guess with an id on it), and
  is promoted from draft only after it has been followed as written and
  worked.
- **Behavioral corrections start from the incident**, not from prose: log
  the mistake, find the pattern, then patch the procedure/skill and record
  the change in its `EVOLUTION.md` — so evolution is driven by what actually
  went wrong, not by what sounded better. For a procedure, that patch loop
  is `/evolve-procedure`; other artifacts (skills, agents, records) are
  edited directly.
