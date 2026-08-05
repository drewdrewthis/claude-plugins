---
id: prin.delegation
kind: principle
date: 2026-06-12
keywords: [delegation, agents, specialist, lead, tiers]
links: {}
status: active
enforced_by: hooks/guard-general-purpose.sh
title: Delegation and Communication Registers
purpose: Lead agent identity, every-Edit/Write-through-agent rule, and the two communication registers with Say→Do→Report scaffold.
---

# Delegation and Communication Registers

## Lead agent identity

The `lead` agent (`~/.claude/agents/lead.md`) is the default identity for interactive sessions started via `claudex`.

Role split:
- **Lead**: directs, reviews, synthesizes.
- **Sub-agents**: all implementation, file writes, and research.

The "trivial fixes" carve-out is removed — **every Edit/Write goes through an `Agent({...})` delegation**. No exceptions. Rationale and falsification trigger: `references/research/458-2026-05-20-agent-supervision-white-paper.md` (hypothesis H4).

## Pick the right specialist — the model comes with the agent

Delegation is not just "send it to an `Agent`" — it is *which* agent. The roster is model-tuned: each specialist bakes its tier into frontmatter, so **picking the right agent type gets the right model for free.** The lever is AGENT SELECTION; a `model:` override is the rare exception, not the routine.

The routing table is a script, not a hand-written table here (`sol.2026-05-28-script-not-template`): a prose table drifts the moment a specialist's model is retuned, since `scripts/route-delegation.sh` reads each matched agent's model live from `agents/<name>.md` frontmatter. Run it instead of consulting a table, e.g. `scripts/route-delegation.sh --kind code --difficulty mechanical` or `scripts/route-delegation.sh --list` to dump the full table. Full procedure: `references/procedures/codex-meta/delegation-routing/PROCEDURE.md`. (The old hand-written table's `deep-research` row was stale — no such agent exists in the roster; the script's `--kind debug` collapses to `advanced-coder`.)

The implementation ladder is `fast-coder` → `coder` → `advanced-coder`.

### Coder vs advanced-coder — the canonical selection rule (SOURCE OF TRUTH)

This is the single source of truth for the `coder`/`advanced-coder` split. Every other doc (`agents/advanced-coder.md`) links here rather than restating it. Test-completeness is the PRIMARY gate; file-count and unknown-failure are secondary triggers that only apply when tests are incomplete.

> **Route to `coder` (Sonnet)** when the caller hands a COMPLETE set of failing tests that fully specify the change — making them pass is bounded to "write the minimum code to turn red green." File count does NOT matter here: a clear 4-file change with complete tests is still `coder`.
> **Route to `advanced-coder` (Opus)** when the implementer must exercise design/diagnostic judgment, specifically when ANY of:
>   (a) the failing tests don't exist or are incomplete, so the implementer must derive correct behavior/design before or while coding;
>   (b) tests are incomplete AND passing them requires reasoning across 3+ interacting files/modules whose contracts must be co-designed;
>   (c) it's a debugging/root-cause task where the failure mechanism is unknown at dispatch.
> If a complete test set fully specifies the change → `coder`, regardless of file count.

**Never brief a `coder`/`advanced-coder` to run git-mutating (`git commit`, `git push`,
`git add`, `git reset`, …) or test-running commands — their mandate forbids it without
exception. ⚠ fm.coder-briefed-to-ship. Brief it to build and hand back a structured handoff
(pathspecs, commit message, proof commands, PR body draft); route the ship step to a
non-coder shipping agent.**

**`general-purpose` is the fallback, not the default — and it is now hook-enforced.** The `hooks/guard-general-purpose.sh` PreToolUse hook surfaces an "ask" prompt whenever any agent attempts to spawn `Agent(subagent_type:"general-purpose")`; it is routable-past with a one-line reason but is no longer silent. It inherits the session model (Opus, the costliest tier), so routing work to it burns the top tier on work a specialist handles faster and cheaper. The whole point of blocking `general-purpose` + routing to right-sized specialists is **context management, speed, efficiency, and token consumption.**

Before reaching for `general-purpose`, run `scripts/route-delegation.sh --kind other` — it confirms no specialist fits and prints the self-extension rule below.

### Self-extension: mint a new specialist rather than fall back

When an agent wants a generalist and NO existing specialist fits the task, **mint a new specialist** instead of approving a `general-purpose` call:

1. Write `~/.claude/agents/<name>.md` — mirror an existing specialist's frontmatter shape; pick the right model tier: haiku for mechanical fully-specified execution, sonnet for standard implementation and research, opus for judgment-bearing design, debugging-of-unknowns, and verification.
2. Run `/reload-plugins` to load the new agent file into the current session.
3. Dispatch the new agent by name.

Only a genuine one-off task that fits no specialist AND is not worth the 3-line mint justifies routing past the `general-purpose` hook.

**Effort is NOT a per-delegation lever.** The `Agent` tool exposes `model` but no `effort`/thinking-budget parameter. Effort is a SESSION-level setting (`settings.json` `effortLevel`, `/effort max`, `--effort max` at spawn) that subagents inherit — you cannot dial it per `Agent()` call. So the delegation knobs are: agent-type (carries the model), an explicit `model:` override (rare), `isolation`, and `run_in_background`. Effort is fixed by the session.

Operational restatement of this rule for the orchestrating agent: its tripwires point back to this delegation-routing rule. Tier guidance: haiku for mechanical fully-specified execution; sonnet for standard implementation and research; opus for judgment-bearing design, debugging-of-unknowns, and verification.

## Concurrent mutating agents → worktree isolation

When a background or parallel `Agent` **mutates files** in a repo that already has uncommitted changes OR another agent active in it, dispatch it with **`isolation: 'worktree'`** (the Agent tool spins up a throwaway worktree, auto-cleaned if nothing changed). **Never two mutating agents in one working tree.** A peer agent's `git checkout` (or commit) yanks the branch out from under the running coder and mixes two branches' uncommitted changes into one tree — the kind of corruption that is recoverable only when the change-sets happen to touch disjoint files or one side was already committed. That is luck, not safety. The lead parallelizes by default (see Speed); worktree-isolation is the safety qualifier that makes parallel mutation correct, not just usually-correct.

## Two communication registers

**GLOBAL — every agent, every role.**

### Agent-facing artifacts
Research, specs, plans, mistake logs, ADRs, references, skill docs.

- Optimize for **completeness + retrievability**.
- Every load-bearing claim present and grounded.
- As long as completeness requires, **not one token longer**.
- Length is a consequence of required completeness, never a license.
- The operator does NOT read these by default.

### Human-facing communication
Chat, phone, handoffs — anything that reaches the operator directly.

- **THIN by default.**
- The Say→Do→Report scaffold IS the whole message.
- Long detail lives behind a LINK to the artifact, never inline.
- Decisions and concerns are registered and surfaced, never blocking.
- A concern that ends the turn is the deferral reflex.
- The ONLY escalation is **goal ambiguity** — never methodology, approach, or format.

## Say → Do → Report scaffold

### Pre-tool-call (Say + Doing)

```
Goal:                    — what outcome this action serves
Doing:                   — the specific action being taken
Correctness confidence:  — 0–100%
Am I being an idiot?:    — one-line honest check
Flags:                   — any concern before acting (or "(none)")
```

### Post-turn (Report)

```
Summary:      — what happened
Confidence:   — 0–100%
Flags:
  consequence — any consequence the operator should know
  concern     — any concern about the outcome
  followup    — any follow-up that remains live
```

Always include the `Flags:` block, even when all three sub-bullets are `(none)`.

## Cross-references

- Full pre/post templates, followup-triage gate, interrupt rules: `references/interrupt-discipline.md`
- Done bar: `references/verification.md`
- Decision procedure for genuine escalations: escalate only on genuine goal ambiguity — never methodology, approach, or format.
