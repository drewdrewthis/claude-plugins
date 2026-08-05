# Agent file template

The canonical shape for any file in `agents/*.md`. Fill in the skeleton below;
delete this explanatory prose from your copy.

Philosophy (thin form, rationale-exile, say-each-thing-once): `prin.agent-facing-docs`
(`references/principles/agent-facing-docs.md`). This template states shape and
rules only — read that file for why.

## Enforcement

`scripts/lint-agent-files.sh` runs in pre-commit over `agents/*.md` (excluding
`agents/EVOLUTION.md`). Hard rules below are BLOCK; a file listed in
`agents/.lint-legacy` gets every violation downgraded to WARN until converted —
see that file's header for the shrink-only-ratchet rule.

**Hard rules (BLOCK, exit 1):**
- R1 — frontmatter block present, with `name:` and `description:` keys
- R2 — a heading whose text is exactly `Role` (any level)
- R3 — a heading whose text is exactly `Boundaries` (any level)
- R4 — no ISO date anywhere in the file (`20[0-9]{2}-[0-9]{2}-[0-9]{2}`)
- R5 — no issue/PR reference anywhere (`#[0-9]+`)

**Size budget (WARN only, never BLOCK — a smell signal, not a correctness gate):**
- agent whose `name` ends in `-reviewer` → target ~80 lines
- every other agent → target ~150 lines

**Missing `model:` in frontmatter** is also WARN only.

`templates/` is not one of the seven record stores (`scripts/lib/stores.sh`),
so this file and files built from it carry no six-key record frontmatter —
just the `name`/`description`/`model`/`tools` block below.

## Skeleton

```markdown
---
name: <agent-id>
description: "<what this agent does + when to use it, one line — this is the only always-loaded text>"
model: <sonnet|opus|haiku>
tools: <optional: comma-separated allowlist; omit for full tool access>
---

# Role

<2-4 lines: what this agent IS. One sentence of scope, one of the core
question it answers. No mission statement, no history of why it exists.>

# Invariants

- <never/always rule, one line>
- <never/always rule, one line>

# Steps

1. <imperative step>
2. <imperative step> — <fused ⚠ warning at the trap site, ≤1 clause, only if non-obvious>
3. <decision step> → <branch condition, if any>

# Delegation

<What this agent does itself vs. hands off, and to whom (agent/procedure name).
Omit this section if the agent never delegates.>

# Boundaries

- <explicit NOT — a thing this agent must not do>
- <explicit NOT>

# Pointers

- <procedure/reference id or path this agent works from>
- <prefer a discovery mechanism (glob, INDEX) over a frozen list when the set can grow>
```

## Section guidance

- **Frontmatter** — `description` is the only text loaded before dispatch;
  make it earn that. `tools` is optional — omit to inherit full access.
- **Role** — identity and the one question this agent answers. Not a resume,
  not a changelog of past redesigns.
- **Invariants** — rules that hold regardless of task. If a rule only applies
  at one step, it belongs fused into that step instead (see Steps).
- **Steps / Operating rules** — either heading is fine; pick one. Steps are
  imperative and ordered; fuse a failure-mode warning inline at the step
  where it bites rather than a separate "gotchas" section.

  **An agent carries its own method.** The steps an agent performs every time
  it runs — how it reads its input, how it decides, the shape it returns — live
  IN the agent file, however long they are. Length is a signal to tighten the
  prose, never a reason to move the method out. A subagent is dispatched with
  its file as the prompt and no conversation; a method behind a pointer is a
  method it may never open.

  Reference a procedure only for work the agent shares with others — a
  multi-actor workflow, a tool's usage, something another agent also runs. That
  is a procedure because it has more than one caller, not because it is long.

  When you do reference one the agent must follow, import it so it auto-expands
  into the prompt. A bare path in prose is a Read the agent pays for, or skips.
  Imports resolve **relative to the agent file**, so from `agents/` it is
  `@../references/...` — plain `@references/...` silently resolves to
  `agents/references/...`:

  ```
  @../references/procedures/<cat>/<name>/PROCEDURE.md
  ```

  ⚠ An `@<path>` that does not resolve expands to NOTHING — no error, no
  warning, and the agent acts without the rules it thinks it has.
  `scripts/lint-claude-imports.sh` covers `agents/*.md`; run it after adding one.
- **Delegation** — only for agents that hand work to others; state what stays
  in-house vs. what gets delegated and to which named agent/procedure.
- **Boundaries** — explicit NOTs. This is what keeps an agent from scope-creeping
  into a neighboring agent's job.
- **Pointers** — procedures, principles, mandates this agent consults. Point at
  the discovery mechanism for an open-ended set (e.g. `references/procedures/`),
  not a hardcoded snapshot that goes stale.

## What NOT to put in an agent file

No ISO dates, no `#123`-style issue/PR references, no incident narration
("this was added after X broke"), no pep talk or role-affirmation prose.
Git history is the archive for why; the agent file carries only what the
agent needs to act. (This template file itself is exempt from R4/R5 — the
lint only runs over `agents/*.md`, and the rule text above necessarily
contains the patterns it forbids.)
