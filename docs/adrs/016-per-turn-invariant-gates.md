# ADR-016: Per-turn invariant gates — three hooks, two agents, one review

**Date:** 2026-08-02
**Status:** Accepted
**Context issue:** [drewdrewthis/orchard-codex#197](https://github.com/drewdrewthis/orchard-codex/issues/197)
**Supersedes:** the procedure-router / done-gate-stop / enforce-protocol /
procedure-nudge generation, all deleted in this work.

## Context

Three invariants were supposed to hold on every turn: call `/respond`, consult
`/how-do-i` before acting, and verify before claiming done. None of them held.

The enforcement they had was advisory — hooks that injected text asking the
agent to comply. Measured across this codebase's own sessions, that text was
routinely ignored; in the session that produced this ADR, `/how-do-i` went
unrun for nine consecutive turns while its reminder fired every time. **Advisory
hook text cannot bind an agent.** A hook either denies the tool call or it is a
suggestion.

The done-check had the opposite problem: it was heavy and it re-asked. A 3-pass
self-grading sweep charged three full turns to have the author re-read their own
prose. The author who missed a gap on pass 1 has no new information on pass 3 —
three self-grades is not three checks.

The owner's constraint on the rebuild: *"I only want the simple and tightest
delivery. no filler, no shit"* and *"modular building with SRP principles."*

## Decision

Three gates, each a hook that **denies**, each binding a different audience.

| Invariant | Hook | Event | Binds |
|---|---|---|---|
| `/respond` | `respond-gate.sh` | PreToolUse | the assistant only |
| `/how-do-i` | `how-do-i-gate.sh` | PreToolUse | every main agent |
| `/am-i-done` | `am-i-done-gate.sh` | Stop | every main agent |

**Subagents are never gated.** A gated subagent deadlocks: it cannot run the
skill that clears the gate, because the skill dispatches a subagent.

Policy lives in the hooks; mechanism lives in four single-responsibility libs:

- `turn-state.sh` — where turn state lives
- `gate-audience.sh` — who an invariant binds
- `gate-allowlist.sh` — what stays permitted while gated (the compliance path)
- `turn-activity.sh` — did this turn call a tool

Two skills act as gateways onto two agents, declared in frontmatter
(`context: fork` + `agent:` + `background: false`), not in prose:

- `how-do-i` → `procedure-scout`, which searches the record stores and returns
  what governs, the commands verbatim, the traps, and a standing label
  (`tested` / `incident-backed` / `asserted`) on every source.
- `am-i-done` → `work-reviewer`, which reads a handoff report and returns
  findings tagged `BLOCKING` / `FOLLOW-UP [same-goal|new-goal]` / `BACKGROUND` /
  `LEAVE`, each carrying its own action.

### Turn state is marker files, not a JSON document

One file per invariant, created by `touch`. Concurrent hooks writing distinct
keys cannot lose each other's updates, because they never write the same file —
the read-modify-write race that broke the previous JSON state (#77) is removed
by construction rather than guarded against.

`ts_reset` deletes **every** key for the session rather than an enumerated list.
This is not a stylistic choice: the enumerated version shipped in this very PR
and silently omitted `am_i_done_asked`, which demoted the Stop gate from
once-per-turn to once-per-session. Enumerating keys in the resetter drifts from
the gates that write them.

### The Stop gate fires after ANY tool call

Owner decision, 2026-08-02: *"it should always gate after any tool calls. This
skips a direct respond, but encourages a second thought about everything else
from research to actual work."*

An earlier draft gated only on durable artifacts (Edit/Write/NotebookEdit/Agent).
That predicate exempted exactly the turns that *check* work — a pure-Bash turn
ending "all green" got no review — and it silently missed `sed -i` mutations,
which are Bash. A purely conversational turn is still exempt: words in a
terminal are answerable by the human reading them.

### The gate asks at most once per turn

If the agent does not run the skill after being asked, the turn is released
anyway. A gate that can ask twice can ask forever, and an unclearable gate
teaches agents to stop verifying in order to escape it.

### Every gate fails open, and blind fail-opens are recorded

No jq, no transcript, unreadable state, reset hook never ran → release. A
PreToolUse hook that blocks on its own bug bricks every session on the box.

But `turn-activity.sh` distinguishes exit 1 ("genuinely no tools") from exit 2
("could not tell"), and the latter is logged to `gate-failopen.jsonl`.
Collapsing the two makes a permanently broken gate indistinguishable from a
permanently clean session — the failure mode that left this box's alerting dead
for nine days and 36 undelivered alerts.

## Consequences

**The compliance path must stay open.** While `/how-do-i` is outstanding, the
gate still permits `Skill`, `Agent`, reads under `references/procedures/`, and
read-only discovery `Bash`. `Agent` is allowlisted unconditionally — which is
also a coverage hole, since an agent can delegate work past both PreToolUse
invariants. The Stop gate re-covers it partially. Accepted deliberately: the
alternative (allowlisting only `Agent` calls targeting the two gate agents) is
more machinery guarding a hole the Stop gate already narrows.

**A turn that only wants `git status` pays a `procedure-scout` fork first.**
That is the invariant working as specified. If per-turn latency becomes the
complaint, the lever is widening the read-only `Bash` shapes, not weakening the
gate.

**`references/canonical-hooks.json` is the install SSOT and must move with any
hook rename.** This work shipped a version that wired two deleted paths and
installed neither new gate; provisioning from it would have landed the whole
architecture inert while every test passed. `canonical-hooks.bats` now asserts
that every wired command exists, that each gate reaches its driving event, and
that no retired hook is still referenced.

> **Amended 2026-08-05** — no longer true. `settings.json` became tracked on
> 2026-08-03, so the wiring was already in git and `canonical-hooks.json` was a
> second drifting copy of it. Both it and `canonical-hooks.bats` are deleted;
> `settings.json` is the wiring SSOT. See
> `dec.2026-08-05-settings-json-is-the-hook-wiring-ssot`. The gate architecture
> this ADR describes is unchanged — only its install mechanism.

**Skills are gateways, and stay few.** A skill gates onto a script, an agent, or
a procedure; with nothing to gate onto it is a procedure in the wrong drawer.
Recorded as `dec.2026-08-02-skill-is-a-gateway-with-context`; enforced by rule
D3 in `lint-doc-shape.sh`.

**A forked skill's body is the subagent's prompt.** Caller-facing instructions
placed there reach the wrong reader — which is why the disposition actions live
in the reviewer's output, not in the `am-i-done` skill body.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Keep advisory nudges, strengthen the wording | Measured not to bind. Nine turns of non-compliance with the reminder firing each time. |
| Keep the 3-pass done sweep | Three self-grades by the author is one check, billed three times. |
| Gate on durable artifacts only | Exempts verification turns — the ones most likely to carry a wrong "done". Rejected by the owner. |
| JSON turn-state document | Lost-update race between concurrent hooks (#77). |
| Gate subagents too | Deadlock: the clearing skill dispatches a subagent. |
| A caller-side procedure for routing findings | The reviewer already decides disposition; shipping the action with the finding removes the document entirely. |

## Evidence

- `bats hooks/tests/*.bats hooks/*.bats` → 232 passing, 0 failing.
  (`bats hooks/tests/` alone is 136; state the command with the count, or the
  number is unreproducible.)
- Each defect fixed in review is pinned by a test that was verified to fail
  against the unfixed code before the fix landed: `gate-libs.bats` "reset clears
  a key it does not enumerate", `gates.bats` "am-i-done: re-arms on the NEXT
  turn", `canonical-hooks.bats` "every canonical hook command exists in the
  tree", `gates.bats` "gates a research-only turn", `gates.bats` "records a
  fail-open when activity cannot be determined".
- Live end-to-end, observed in the authoring session and not reproducible from
  this repo: a cold agent in an isolated `HOME`, told to write a file, attempted
  `Write`, was denied, and recovered unaided — *"A hook blocked the write until
  the gate skill runs. Running it."* Recorded as testimony, not as evidence a
  reader can re-run.
- `work-reviewer` was tested against a deliberately flawed report and caught the
  contradicted claim, the bare `(checked)` evidence, and correctly declined to
  blame a pre-existing failure on the work.
