---
id: proc.codex-meta.create-skill
kind: procedure
date: 2026-06-25
keywords: [create-skill, new-skill, skill-design, claude-code-skill, workflow]
links: []
status: active
---

# Create Skill

Creates a new `SKILL.md` (plus optional `references/`, `templates/`, `scripts/`)
for an operation that earns an invocation handle.

## Steps

### 0. Skill vs procedure gate

A skill is a **gateway with context** — it gates onto a script, an agent, or a
procedure. If it gates onto nothing, it is a procedure filed in the wrong
drawer.

Litmus: "Will the user ever type `/<this>`?" No → it belongs as
`references/procedures/<area>/<name>/PROCEDURE.md` plus a testable script. Stop
here and write that instead (`create-procedure.procedure.md`).

Keep skills FEW. Workflow content lives in the procedure record; the skill
carries only what is true at the moment of invocation.

In-repo examples: `am-i-done` gates onto the `work-reviewer` agent; `take-note`
wraps a script; `evolve-procedure` is a thin wrapper over a procedure record.

### 1. Capture intent

Extract from conversation history first — don't re-ask what's demonstrated.

1. What does this skill do? One sentence. If you can't, split it.
2. When should it trigger? Specific phrases and contexts.
3. What's the output? Files, messages, state changes, delegated work.
4. Does it need tools/agents? Which ones, any MCP servers.
5. Fork or inline? Read `docs/principles/delegation.md` § "Skills vs agents, execution modes, task-tracking".

### 2. Landscape check

1. **Local** — scan the installed plugins' `skills/` dirs and `.claude/skills/` for overlapping functionality.
2. **Official** — [anthropics/skills](https://github.com/anthropics/skills) for maintained skills and `/skill-creator` reference.
3. **Community** — [skills.sh](https://skills.sh). Run `npx skills find <keyword>` or search the web.
4. **Prior art** — search `"claude code skill" <topic>` or `"AGENTS.md" <topic>`. See [agentskills.io](https://agentskills.io/) for format conventions.

If a close match exists: install/adapt and cite source in `<!-- adapted from: ... -->`. If partial, use as starting point. If none, continue.

### 3. Write the skill

**Directory structure** — no symlinks anywhere.

```
plugins/<plugin>/skills/<skill-name>/   # a plugin-shipped skill (this repo)
├── SKILL.md              # Required
├── references/           # Optional — docs loaded on demand
├── templates/            # Optional — record/report shapes
└── scripts/              # Optional — deterministic/repetitive tasks

~/.claude/skills/<skill-name>/SKILL.md  # a host-local skill
```

⚠ Reference bundled files by `${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}`,
never by a relative path — a relative path resolves against the caller's cwd.

**SKILL.md anatomy**

```yaml
---
name: <slug>                    # kebab-case identifier
description: "<what + when>"    # PRIMARY trigger — specific and slightly pushy
user-invocable: true            # false only for skills invoked exclusively by other skills
argument-hint: "[args]"         # Optional
# Optional fields:
context: fork                   # Only if skill needs isolation (reviews, parallel work)
agent: <agent-type>             # Only if delegating to a specific agent
allowed-tools: [Tool1, Tool2]  # Only if restricting tool access
---
```

⚠ **Verify the field list against https://code.claude.com/docs/en/skills before writing frontmatter — it changes, and your recall is stale.**

**Frontmatter mistakes**

| Mistake | Correct |
|---------|---------|
| `context: conversation` or other invented values | Only valid value is `context: fork`. Omit entirely for inline behavior. |
| `context: fork` without `agent:` | Valid — SKILL.md becomes the agent prompt, run by `general-purpose`. Add `agent:` for a specific reusable agent type. |
| `context: fork` without `background: false`, when the caller needs the result | **`background` defaults to TRUE** — the fork runs async and the caller does NOT wait. Any skill whose output the caller must act on this turn needs `background: false`. |
| Writing "dispatch the X agent" in the body | The harness spawns it from `agent:`. Prose telling the model to dispatch is not the mechanism. |
| Caller-facing guidance in a forked skill's body | The body IS the subagent's prompt and the caller never reads it. Put caller-side steps in a procedure record. |
| Assuming the subagent can see the conversation | It gets **no** history. Everything it needs arrives in the body and `$ARGUMENTS`. |
| `${CLAUDE_SKILL_DIR}` in the `description` | The description is a raw always-loaded string — substitution does not reach it. Name the location in words. |

**Body guidelines**

| Principle | Rule |
|-----------|------|
| **Length** | Under 100 lines simple, under 300 complex. Approaching 500 → split into SKILL.md + references/ |
| **Style** | Imperative voice. Explain *why* only when removing it causes a wrong result. |
| **Structure** | Numbered steps. Skills with 4+ phases need task tracking — see `docs/principles/delegation.md` § "Skills vs agents, execution modes, task-tracking" |
| **Arguments** | Use `$ARGUMENTS` placeholder for pass-through |
| **Token budget** | Cut instructions the model follows anyway. Don't repeat CLAUDE.md. |
| **Examples** | 1–2 for non-obvious output formats only. |
| **References** | Large docs (>50 lines) → `references/` with a pointer from SKILL.md |

**Description field**

Must include what (capability) + when (trigger phrases). Under ~50 words, specific enough to trigger reliably. Err pushy — Claude undertriggers. Better to trigger unnecessarily than miss a relevant invocation.

**Progressive disclosure**

| Level | Content | Size target |
|-------|---------|-------------|
| Metadata | name + description | ~50 words |
| SKILL.md body | steps + rules | <200 lines |
| Bundled resources | references/, templates/, scripts/ | unlimited |

Move reference material to `references/`. Move deterministic logic to `scripts/`.

### 4. Validate

1. Read it fresh — does it make sense without conversation context?
2. Delete any line the model follows without being told.
3. Would a fresh session know what to do?
4. Given 3 realistic prompts, would the description trigger?
5. Under 200 lines? If not, move content to references/.

Present the skill to the user.

### 5. Place it

Ask for scope if unclear: a plugin-shipped skill (`plugins/<plugin>/skills/<name>/`,
installed on every host that installs the plugin) or a host-local one
(`~/.claude/skills/<name>/`, this box only). Write `SKILL.md` at the chosen path
and tell the user it is ready to commit — don't auto-commit.

Draft-then-promote applies: ship it, then tighten it from how it actually
performed rather than from how it reads.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Kitchen-sink skills — doing 5 things | Split into 1-thing skills |
| Verbose instructions — model knows this | Trust its intelligence; cut |
| Description says "do X" but not "when" | Add trigger phrases |
| Hardcoded paths | Use `${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}` — relative paths resolve against the caller's cwd |
| Duplicating CLAUDE.md content | Delete it; global instructions already apply |
