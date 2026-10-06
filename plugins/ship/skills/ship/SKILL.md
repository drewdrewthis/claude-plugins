---
name: ship
description: The one delivery flow for shipping code — launch a worker, implement an issue, orchestrate coders, review, browser-QA against the running app, open the PR and monitor it to green. Use this whenever the user says implement, build, fix, ship, deliver, start work on an issue, launch a worker/session, or when you are an agent that has just been launched to do coding work — even if they don't say "ship". Also fires on — get this PR green, fix CI, drive this PR. NOT for — docs-only edits, one-line config tweaks, answering questions, or ops work — those don't need the full flow.
---

# ship

<!-- PLUGIN ADAPTATION (plugin-hosting context): own-file references use ${CLAUDE_PLUGIN_ROOT} instead of orchard-codex's ~/.claude/skills paths; vendored from orchard-codex@develop-sweatshop skills/ship. External scripts/hooks/records it cites (session-truth, pr-ready-check.sh, ship-flow-stop.sh, ~/.knowledge records) are NOT shipped by this plugin — see README. -->

Four modes. Figure out which one you're in, read that reference file, execute it. Do not skip modes — a mode you skip is a gate you didn't clear.

| You are... | Mode | Reference |
|---|---|---|
| Starting a fresh worker/session for an issue | **LAUNCH** | `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/launch.md` |
| The worker, told to implement an issue | **IMPLEMENT** | `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/implement.md` |
| Convergence reported done, need review + proof | **REVIEW/QA** | `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/review-qa.md` |
| Ready to open/drive the PR | **PR + MONITOR** | `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/monitor.md` |

Deep-dive source procedures (cited inline in each reference, not required reading for the happy path):
- `~/.knowledge/modules/shared/records/procedures/planner-orchardist-loop/implement/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/procedures/planner-orchardist-loop/orchestrate/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/principles/delegation.md`, `~/.knowledge/modules/shared/records/procedures/codex-meta/delegation-routing/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/procedures/review-qa/browser-qa/PROCEDURE.md`, `~/.knowledge/modules/shared/records/procedures/boxd/boxd-browser-test/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/procedures/github/drive-pr/PROCEDURE.md`, `~/.knowledge/modules/shared/records/procedures/review-qa/pr-ready-check/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/principles/ci-green-before-ready.md`
- `~/.knowledge/modules/shared/records/session-spawn-recipe.md`, `~/.knowledge/modules/shared/records/procedures/fleet-session/lifecycle/PROCEDURE.md`
- `~/.knowledge/modules/shared/records/procedures/review-qa/review-methodology/PROCEDURE.md`

## Flow-state flag file

Write/update `/tmp/claude-ship-flow-$CLAUDE_SESSION_ID` at every phase transition:

```bash
echo '{"pr": <N or null>, "phase": "implement|review|browser-qa|monitor|done"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

A Stop hook (`~/.claude/hooks/ship-flow-stop.sh`) reads this file and blocks premature completion. Set `"phase": "done"` **only** after `pr-ready-check.sh` exits 0/READY **and** browser proof (or documented no-UI-surface exception) is embedded in the PR body. Setting `done` early defeats the hook's purpose — don't.

## Resuming mid-flow

At the start of every turn, before anything else: `cat /tmp/claude-ship-flow-$CLAUDE_SESSION_ID 2>/dev/null`. If it exists you are mid-ship-flow — read the reference for its phase (implement→implement.md, review/browser-qa→review-qa.md, monitor→monitor.md) and continue. Do not restart from mode selection.

## Non-negotiables (apply in every mode)

- **Delegate every Edit/Write.** The lead/orchestrating identity directs; specialists implement. Pick the right specialist — see `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/implement.md`.
- **No use-proof = not done.** Screenshots of the change being USED — browser for UI; real SDK/API/MCP/CLI invocation for everything else — against the running app or production. Tests are never the proof.
- **Evidence over assertion.** "Done" means a verification you ran this turn — a screenshot, a passing CI run, a command output — never a self-report.
- **A question-shaped owner message is never a go.** An owner line ending in "right?", "should we…?", or "why not…?" gets an answer, not a dispatch — wait for an explicit go before starting rework. Anti-example (owner, 2026-09-23, orchard-codex#435): `"so, after the work we did to fill the gaps app-side, we just need to match that saas side, right? and then do the opt-in work. It seems like we made some mistakes, but we can abandon bad choices before merging. merging a mistake now and then filing a fix is a stupid strategy"` and `"so, we should abandon 1255, then -- it seems like the problem is solved by an existing pattern. why not have the infra c…"` — both were read as consent and triggered dispatch; the owner had given neither.
- **Fastest path wins** — smallest diff, no tangents, no gold-plating, decide once and move.

## Boundaries

- This skill replaces the `superpowers`/`caveman` methodology skills and `ralph-loop` for the delivery flow — do not invoke those; use the Monitor tool + iteration loop directly (`${CLAUDE_PLUGIN_ROOT}/skills/ship/references/monitor.md`).
- Don't re-plan inside `ship`. If the plan/ACs are missing, that's the readiness gate failing — go fix it (`${CLAUDE_PLUGIN_ROOT}/skills/ship/references/implement.md`), don't improvise a new plan.
- Don't skip straight to PR + monitor without review-qa. A PR opened without browser proof is not ready regardless of what CI says.
