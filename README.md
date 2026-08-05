# claude-plugins

Drü's Claude Code plugin marketplace. Versioned home for the machinery shared
across the personal fleet AND the AppleTree tenant base — one source, two
consumers, no copy drift. **Machinery only:** the knowledge files the agent
generates live outside the plugins, under `~/.claude/references/**` per the
design record.

## Install

```
/plugin marketplace add drewdrewthis/claude-plugins
/plugin install procedures@drewdrewthis
/plugin install take-note@drewdrewthis
```

## Plugins

### procedures (0.1.0)

The procedural-knowledge system, gates included (gate hooks vendored from
orchard-codex `develop-sweatshop`):

| piece | what |
|---|---|
| `/how-do-i` | routes a question across procedures, solutions, decisions.jsonl, shipped docs, and `/recall` history before improvising |
| `/log` | durable records: procedure / decision / solution, templates in `skills/log/templates/` |
| `/am-i-done` | cold-read review of a handoff report by the `work-reviewer` agent before calling work done |
| `how-do-i-gate` (PreToolUse) | blocks tool calls until `Skill(how-do-i)` has run this turn; fail-open, blind fail-opens recorded |
| `am-i-done-gate` (Stop) | requires one `Skill(am-i-done)` review on any turn that called tools; asks at most once |
| `turn-state-reset` (UserPromptSubmit) / `turn-state-record` (PostToolUse:Skill) | the turn-boundary state the gates read (`$TURN_STATE_DIR`, default `/tmp/claude-turn-state`) |

Config (env, optional): `KNOWLEDGE_REFS` — record root (default
`~/.claude/references`): `procedures/`, `solutions/`, `decisions.jsonl`
(`KNOWLEDGE_DECISIONS` overrides the jsonl path). `HOW_DO_I_EXTRA_DOCS` —
extra shipped-docs dir the router also searches. `RECALL_SCRIPT` — recall
search script for the history surface; degrades gracefully if absent.

### take-note (0.1.0)

Daily working notes: `/take-note` scratchpad (one file per day, rollover with
carry-over) + a SessionStart hook loading today's (or yesterday's) note and
`ABOUT_MY_PERSON.md` when present. Config: `KNOWLEDGE_WS` (default
`~/workspace`) or `NOTES_DIR` directly.

Origin: skills extracted 2026-08-05 from `appletree-base`; gates from
`orchard-codex@develop-sweatshop`.
