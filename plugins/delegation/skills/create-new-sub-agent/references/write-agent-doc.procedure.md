---
id: proc.codex-meta.write-agent-doc
kind: procedure
date: 2026-06-09
keywords: [codex-meta, write-agent-doc, agent-doc, author, skill, reference, bloat, agent-facing]
links: {}
status: active
---

# write-agent-doc

## Procedure

**MUST READ first:**
- `$CODEX_ROOT/references/principles/agent-facing-docs.md` where the host carries the codex principles — the principles you are applying.
- this skill's `templates/agent.template.md` — the canonical shape for any `agents/*.md` file (section order, hard rules R1-R5, size budgets).

1. Apply the principles — existing doc: rewrite to them; new doc: fill the skeleton. For an `agents/*.md` file, fill the template's skeleton directly.
2. **Coverage gate** (existing doc): enumerate every load-bearing claim in the original and confirm each survives, or note why it was dropped.
3. For an `agents/*.md` file, run `scripts/lint-agent-files.sh` — it enforces the template's hard rules R1-R5 (BLOCK) and size budget (WARN). A file listed in `agents/.lint-legacy` gets hard-rule violations downgraded to WARN until converted; once it passes, remove it from that list.
4. Commit and push your changes.

> **Dispatch note:** a newly-written agent file is NOT dispatchable as a native `subagent_type` in the session that created it — agents load at session start. Run `/reload-plugins` (or start a fresh session) before invoking the new agent by name. Once loaded, dispatch the new agent directly by its `subagent_type` name — do NOT route through `general-purpose`, which is hook-blocked.
