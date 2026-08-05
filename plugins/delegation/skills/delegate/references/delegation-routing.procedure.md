---
id: proc.codex-meta.delegation-routing
kind: procedure
date: 2026-06-12
keywords: [delegation, routing, specialist, agent, tier, fast-coder, coder, advanced-coder, scribe, researcher, planner, general-purpose, model-selection]
links: { principles: [prin.delegation], failure-modes: [fm.wrong-subagent-tier] }
status: active
---
# Delegation routing — pick the right specialist   ⚠ fm.wrong-subagent-tier — routing miss is a cost leak; lever is AGENT SELECTION not `model:` override

## The table

| Task shape | Agent | Model (baked in) |
|---|---|---|
| Mechanical, fully-specified, NO judgment — file rewrites from an exact spec, find/replace, one-line appends, boilerplate, INDEX/ref updates | **`fast-coder`** | Haiku |
| Standard implementation, test writing | **`coder`** | Sonnet |
| Hard / judgment-bearing TDD — incomplete/absent tests, co-designing contracts across interacting modules, root-causing unknown failures | **`advanced-coder`** | Opus |
| Read-only codebase exploration / "go find X" / "how does X work" / multi-file search | **`researcher`** | Sonnet |
| Durable non-code prose — docs, references, memory, ADRs, research reports, READMEs, doc-comments | **`scribe`** | Sonnet |
| Multi-file design/impl planning — step plan + tradeoffs + draft ACs for ac-reviewer | **`planner`** | Opus |
| Code/design review | `principles-reviewer` / `hygiene-reviewer` / `security-reviewer` / `test-reviewer` / `proof-reviewer` | Sonnet/Opus per agent |
| AC sharpening | `ac-reviewer` | Opus |
| Adversarial stress-test | `devils-advocate` | Opus |
| Multi-file reasoning, complex debugging | `advanced-coder` | Opus |
| Genuinely novel work no specialist fits AND not worth minting | `general-purpose` (**HOOK-BLOCKED** — harness surfaces an ask; last resort only) | inherits session (Opus) |

## Self-extension rule

When no existing specialist fits, write `agents/<name>.md` with a right-sized model + tools, then `/reload-plugins`. Tier guidance: haiku for mechanical fully-specified execution; sonnet for standard implementation and research; opus for judgment-bearing design, debugging-of-unknowns, and verification. Only a genuine one-off that is not worth minting justifies an approved `general-purpose` call.
