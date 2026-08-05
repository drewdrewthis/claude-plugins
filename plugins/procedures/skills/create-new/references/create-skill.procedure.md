---
id: proc.codex-meta.create-skill
kind: procedure
date: 2026-06-25
keywords: [create-skill, new-skill, skill-design, claude-code-skill, workflow]
links: []
status: active
---

# Create Skill

Context: $ARGUMENTS

## Steps

### 0. Skill vs procedure gate

A skill is a **gateway with context** — it gates onto a script, an agent, or a procedure (`dec.2026-08-02-skill-is-a-gateway-with-context`). If it gates onto nothing, it is a procedure filed in the wrong drawer.

Litmus: "Will the user ever type `/<this>`?" No → it belongs as `references/procedures/<area>/<name>/PROCEDURE.md` + co-located testable script. Stop here and write that instead.

Keep skills FEW. Workflow content lives in the PROCEDURE.md; the skill carries only what is true at the moment of invocation.

Canonical split: `send-to-session` → procedure + script. `tmux-self-compact` → skill (human invokes it, delegates to that script). `how-do-i` → skill gating onto the `procedure-scout` agent.

### 1. Capture intent

Extract from conversation history first — don't re-ask what's demonstrated.

1. What does this skill do? One sentence. If you can't, split it.
2. When should it trigger? Specific phrases and contexts.
3. What's the output? Files, messages, state changes, delegated work.
4. Does it need tools/agents? Which ones, any MCP servers.
5. Fork or inline? Read `references/principles/delegation.md` § "Skills vs agents, execution modes, task-tracking".

### 2. Landscape check

1. **Local** — scan `~/.claude/skills/` and `.claude/skills/` for overlapping functionality.
2. **Official** — [anthropics/skills](https://github.com/anthropics/skills) for maintained skills and `/skill-creator` reference.
3. **Community** — [skills.sh](https://skills.sh). Run `npx skills find <keyword>` or search the web.
4. **Prior art** — search `"claude code skill" <topic>` or `"AGENTS.md" <topic>`. See [agentskills.io](https://agentskills.io/) for format conventions.

If a close match exists: install/adapt and cite source in `<!-- adapted from: ... -->`. If partial, use as starting point. If none, continue.

### 3. Write the skill

**Directory structure**

```
~/.claude/skills/<skill-name>/   # canonical source (global skills) — the codex checkout itself
├── SKILL.md              # Required
├── references/           # Optional — docs loaded on demand
│   └── detailed-guide.md
└── scripts/              # Optional — deterministic/repetitive tasks
    └── helper.py

~/.claude/skills/<skill-name>  →  symlink to the codex path above
```

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

⚠ **Verify the field list against https://code.claude.com/docs/en/skills before writing frontmatter — it changes, and your recall is stale.** As of 2026-08: `name` `description` `when_to_use` `argument-hint` `arguments` `user-invocable` `disable-model-invocation` `allowed-tools` `disallowed-tools` `model` `effort` `context` `agent` `background` `hooks` `paths` `shell`.

**Frontmatter mistakes**

| Mistake | Correct |
|---------|---------|
| `context: conversation` or other invented values | Only valid value is `context: fork`. Omit entirely for inline behavior. |
| `context: fork` without `agent:` | Valid — SKILL.md becomes the agent prompt, run by `general-purpose`. Add `agent:` for a specific reusable agent type. |
| `context: fork` without `background: false`, when the caller needs the result | **`background` defaults to TRUE** — the fork runs async and the caller does NOT wait. Any skill whose output the caller must act on this turn needs `background: false` (requires >= 2.1.218). |
| Writing "dispatch the X agent" in the body | The harness spawns it from `agent:`. Prose telling the model to dispatch is not the mechanism. |
| Caller-facing guidance in a forked skill's body | The body IS the subagent's prompt and the caller never reads it. Put caller-side steps in a PROCEDURE.md. |
| Assuming the subagent can see the conversation | It gets **no** history. Everything it needs arrives in the body and `$ARGUMENTS`. |

**Body guidelines**

| Principle | Rule |
|-----------|------|
| **Length** | Under 100 lines simple, under 300 complex. Approaching 500 → split into SKILL.md + references/ |
| **Style** | Imperative voice. Explain *why* only when removing it causes a wrong result. |
| **Structure** | Numbered steps. Skills with 4+ phases need task tracking — see `references/principles/delegation.md` § "Skills vs agents, execution modes, task-tracking" |
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
| Bundled resources | references/, scripts/ | unlimited |

Move reference material to `references/`. Move deterministic logic to `scripts/`.

### 4. Validate

1. Read it fresh — does it make sense without conversation context?
2. Delete any line the model follows without being told.
3. Would a fresh session know what to do?
4. Given 3 realistic prompts, would the description trigger?
5. Under 200 lines? If not, move content to references/.

Present the skill to the user.

### 5. Place it

Ask for scope (global vs project) if unclear.

**Global:**
```bash
mkdir -p ~/.claude/skills/<name>
# write SKILL.md there — ~/.claude IS the codex checkout, so it is already tracked
```
⚠ No symlink. An older revision had the skill live in `~/workspace/orchard-codex/skills/` and symlinked into `~/.claude/skills/`; that model is retired (`find ~/.claude/skills -maxdepth 1 -type l` → 0). On the sweatshop `~/workspace/orchard-codex` is a second checkout stuck on an April branch — writing a skill there strands it off `develop-<machine>` while the symlink still resolves locally, so it looks fine and never lands.
Tell the user the skill is ready to commit. Don't auto-commit.

**Project:** create at `<repo>/.claude/skills/<name>/SKILL.md`. No symlink needed.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Kitchen-sink skills — doing 5 things | Split into 1-thing skills |
| Verbose instructions — model knows this | Trust its intelligence; cut |
| Description says "do X" but not "when" | Add trigger phrases |
| Hardcoded paths | Use relative paths or `$ARGUMENTS` |
| Duplicating CLAUDE.md content | Delete it; global instructions already apply |
