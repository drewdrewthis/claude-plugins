# claude-plugins

Drü's Claude Code plugin marketplace. Versioned home for skills shared across
the personal fleet AND the AppleTree tenant base — one source, two consumers,
no copy drift.

## Install

```
/plugin marketplace add drewdrewthis/claude-plugins
/plugin install knowledge@drewdrewthis
```

## Plugins

### knowledge (0.1.0)

The working-memory + procedural-knowledge layer:

| piece | what |
|---|---|
| `/take-note` | daily scratchpad, one file per day, rollover with carry-over |
| `/log` | durable records: procedure / decision / solution, templates included (`skills/log/templates/`) |
| `/how-do-i` | routes a question across procedures, solutions, decisions.jsonl, shipped docs, and `/recall` history before improvising |
| SessionStart hook | loads today's (or yesterday's) note + `ABOUT_MY_PERSON.md` if present |

**Configuration (env, all optional):**

- `KNOWLEDGE_REFS` — knowledge root (default `~/.claude/references`): holds
  `procedures/`, `solutions/`, `decisions.jsonl` (`KNOWLEDGE_DECISIONS`
  overrides the jsonl path alone).
- `KNOWLEDGE_WS` — daily-notes root (default `~/workspace`): holds `notes/`
  (`NOTES_DIR` overrides directly) and, if present, the
  `references/docs/ABOUT_MY_PERSON.md` the SessionStart hook loads.
- `HOW_DO_I_EXTRA_DOCS` — extra shipped-docs dir the router also searches.
- `RECALL_SCRIPT` — path to a recall search script for the history surface;
  degrades gracefully if absent.

Origin: extracted 2026-08-05 from `appletree-base` so the personal fleet and
the tenant base stop sharing a base repo for these.
