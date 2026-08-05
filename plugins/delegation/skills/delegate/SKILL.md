---
name: delegate
description: "Hand a task to the right specialist subagent instead of doing it yourself. Routes a task shape to an agent + model from your own roster, then builds the briefing that makes the handoff land. Use whenever work could go to a subagent — implementation, search, prose, planning, review, AC sharpening, stress-testing, debugging, audits — or when you catch yourself about to do specialist work inline."
user-invocable: true
argument-hint: "<the task to delegate>"
---

# /delegate — pick the specialist, then brief it properly

Routing is the script's job; the briefing is yours.

## 1. Classify the task shape

Three axes. Only `kind` is always required.

- **kind** — `code` | `search` | `prose` | `plan` | `review` | `ac` | `stress-test` | `debug` | `audit` | `other`. Name what the task PRODUCES (a diff, an answer, a doc, a plan, a verdict), not what it is about.
- **difficulty** (`code` only) — `mechanical` when the change is fully specified and needs no judgment, `standard` when tests or spec fully determine the change, `hard` when you must derive the behavior, co-design contracts across modules, or root-cause an unknown failure.
- **focus** (`review` only) — `principles` | `hygiene` | `security` | `test` | `proof`: pick the one question the review must answer; running all five on a small diff is waste.

## 2. Route

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/route-delegation.sh" --kind <kind> [--difficulty <d>|--focus <f>]
```

It answers `agent`, `model`, and `why`, reading each model live from your roster's frontmatter — so a retuned roster propagates without editing anything here. `--list` dumps every route.

| exit | meaning | what to do |
|---|---|---|
| 0 | matched | dispatch that agent by name |
| 1 | usage error | fix the flags (`--kind code` needs `--difficulty`; `--kind review` needs `--focus`) |
| 2 | no specialist fits, or this host has no roster yet | follow the printed self-extension rule — mint one with `/create-new-sub-agent` |
| 3 | roster drift — the matched agent's file or `model:` key is missing | fix the roster first; do not delegate around a broken entry |

Config: `CLAUDE_AGENTS_DIR`, else `$CODEX_ROOT/agents`, else `~/.claude/agents`.

## 3. Build the briefing

This is the half no script can do.

- **Self-contained.** The subagent sees NOTHING of your context — no files you read, no decisions you made, no thread. Every path, constraint, and prior finding it needs goes in the brief or does not exist.
- **Demand the RESULT, not narration.** "I have delegated…", "I would…", "the approach would be…" is not a result. Name the artifact you require back: diffs, absolute file paths, command output, a verdict with evidence.
- **Never brief a `coder`/`advanced-coder` to run git-mutating or test-running commands.** They build and hand back a structured handoff — pathspecs, a commit message, the proof commands to run. You ship and validate; a subagent that commits its own unvalidated work removes the review you delegated FOR.
- **For `code` kinds, weave in the binding standards.** Read `$CODEX_ROOT/references/principles/coding.md` (default `~/.claude/references/principles/coding.md`) and inject the sections the task actually touches — a pointer the subagent may never open is not a standard it follows.
- **For `prose`/doc kinds, do the same with `agent-facing-docs.md`** from the same directory.

## 4. Verify what comes back

A subagent's report is a claim, not evidence. Before acting on it, run the cheapest disconfirming check — read the file it says it wrote, run the command it says passes, diff what it says it changed.

Full routing rationale: `${CLAUDE_SKILL_DIR}/references/delegation-routing.procedure.md`.
