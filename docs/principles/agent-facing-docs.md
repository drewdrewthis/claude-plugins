---
id: prin.agent-facing-docs
kind: principle
date: 2026-06-12
updated: 2026-06-19
keywords: [agent-facing, docs, retrievable, complete, thin-form, fused-warning, rationale-exile]
links: {}
enforced_by: hygiene-reviewer
status: active
title: Agent-facing documentation
purpose: How to write any doc whose only reader is another agent — completeness is the floor, "not one token longer" is the ceiling.
next: []
---

# Agent-facing documentation — best practices

Principles for act-docs: agent role files, `SKILL.md` files, inline references. Completeness is the floor, "not one token longer" is the ceiling. Applied by the `scribe` agent (`agents/scribe.md`).

**Load-bearing idea:** the intelligence is in the agent, not the doc. A live reasoner fills gaps, infers intent, re-derives rationale. An act-doc carries only what it cannot regenerate: **ordered steps + fused fm-warnings + edges.** Everything else is prose the agent already brings — storing it is bloat. (Note: a *spec* like this one legitimately carries WHY, because the reader needs the reasoning to apply the spec correctly; act-docs do not.)

Counterpart for human-facing output: [[human-facing-writing]] (`human-facing-writing.md`).

## Principles

1. **Say each thing once.** One canonical home per rule; cross-reference, never restate.
2. **Point at discoverable sets; never freeze them.** Reference the discovery mechanism (`ls ~/.claude/agents/`, an INDEX file), don't hardcode a snapshot — frozen copies go stale silently. Dynamic sibling of #1. (Failure case: research 2031.)
3. **Cut human-register prose** — pep talk, role-affirmation, recap/summary/morale sections.
4. **Never trim a constraint, boundary, step, edge, or failure-mode the agent needs; when unsure, it stays.** Only redundancy is cuttable.
5. **Contradictions are bugs.** Resolve to one statement (reasoned passage beats casual leftover); escalate only genuine ambiguity.
6. **The frontmatter `description` is the only always-loaded text** — make it say what + when, precisely.
7. **Exile rationale.** DELETE WHY/rationale/motivation/restatement/behavior-neutral examples — git history is the archive. If the history has standing value beyond git log (a backstory worth finding without a blame-dig), relocate it to the sibling `EVOLUTION.md` or a `references/research/`/`references/solutions/` record in the same commit — procedural and core docs carry only the present tense. EXCEPTION: keep a single inline WHY clause only when removing it causes a wrong or unsafe result. Same test as #4 — "does the agent need this to act correctly?"
8. **Be token smart** Say as little as possible as concisely as possible.

## Agent-doc skeleton (thin form)

Omit sections not needed. Frontmatter declares edges; steps fuse the failure-mode warning at the trap site.

```
---
name: <id>
description: <what + when, one line>
next: [proc-id, ...]          # always-follows edges
branches: { "label": proc-id } # conditional edges
---
# Role          — what this agent IS
# <rules>       — one section per load-bearing rule
## Steps
1. <imperative step>
2. <imperative step>   ⚠ fm.<id> — <≤1-clause warning>
3. <decision> → branches: { "<condition>": <proc-or-skill.id> }
# Boundaries    — explicit NOTs
```

## Rationale-exile: before/after

**Before (fat — 8 lines):**
```
## Why we validate before writing
Validation catches malformed input early and prevents partial writes that leave
the store in an inconsistent state. This is especially important because the
downstream consumer has no error-recovery path.

1. Read the target record.
2. Write the updated record.

## Failure modes
- fm.partial-write: agent skips validation, downstream consumer crashes.
  Fix: always validate before writing.
```

**After (thin — 4 lines):**
```
## Steps
1. Read the target record.
2. Validate the payload before writing.   ⚠ fm.partial-write — downstream has no error-recovery path
3. Write the updated record.
```

Rationale paragraph gone. Surviving WHY clause passes the test — remove it and the agent may skip validation believing errors are recoverable.

## Doc-class carve-outs

- **Command-reference procedures** (payload = copy-paste snippets like `gh api graphql`): keep commands VERBATIM — thin only the surrounding wrapper prose.
- **Record-stores** (`references/{decisions,research,solutions,adrs}/`, `plans/`): these are rationale-BY-PURPOSE (the queryable archive). Do NOT apply the act-doc thin form to them; their WHY is their value. (All other `references/` docs — e.g. `principles/` — ARE act-docs and in scope.)

Official skill docs: https://code.claude.com/docs/en/skills
