---
name: create-new-sub-agent
description: "Mint a new specialist subagent when no existing one fits a recurring task shape. Writes a right-sized agent file — single mandate, model tier, tools allowlist, tripwires — into your agent roster and lints it. Use after /delegate's router exits 2, or when you notice yourself repeatedly hand-briefing the same kind of work."
user-invocable: true
argument-hint: "<what the specialist is for>"
---

# /create-new-sub-agent — extend the roster

## 1. Check the router first

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/route-delegation.sh" --list
```

A task shape that already routes needs a better BRIEF, not a new agent. Mint only when the router genuinely has no row for the shape (exit 2), and the shape recurs — a one-off is a `general-purpose` call with a reason, not a roster entry.

## 2. Write the file

Read `${CLAUDE_SKILL_DIR}/references/write-agent-doc.procedure.md`, then fill the skeleton in `${CLAUDE_SKILL_DIR}/templates/agent.template.md`. What the template is for:

- **A single mandate.** One agent, one question it answers. Two mandates is two agents.
- **A right-sized model tier, with the justification written down.** Haiku for mechanical, Sonnet for standard, Opus for judgment — the tier is the cost lever, so say why this one.
- **A tools allowlist.** Omit only when the agent genuinely needs full access; a read-only agent with Write is a tripwire waiting to fire.
- **Tripwires in `Boundaries`.** Explicit NOTs are what keep the new agent out of a neighbor's job.

The template's MUST-READ is `agent-facing-docs.md` — in your host codex at `$CODEX_ROOT/references/principles/agent-facing-docs.md`, and vendored in this repo at `docs/principles/agent-facing-docs.md`. The agent file IS the prompt: it carries its own method inline, because a subagent dispatched with no conversation may never open a pointer.

## 3. Write it to the roster, then validate

Destination: `${CLAUDE_AGENTS_DIR:-$CODEX_ROOT/agents}` (default `~/.claude/agents`) as `<name>.md`.

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/lint-agent-files.sh" <file>
```

Hard rules (exit 1): frontmatter with `name:`/`description:`, a `Role` heading, a `Boundaries` heading, no ISO dates, no `#NNN` issue refs. Size budget and a missing `model:` warn only. Paths are relative to the lint root — set `LINT_AGENT_FILES_ROOT` (or `CODEX_ROOT`) if your roster is not under `~/.claude`.

## 4. Reload

Agents load at session start: the file you just wrote is NOT dispatchable in this session until you reload plugins or start a fresh session. Verify it routes (`--list`, or re-run the `/delegate` classification) before briefing it, then dispatch it by name — not through `general-purpose`.
