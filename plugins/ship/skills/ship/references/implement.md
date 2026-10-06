# IMPLEMENT mode

You were launched (or told) to implement an issue. Set the flag file first, then gate, then delegate.

```bash
echo '{"pr": null, "phase": "implement"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

If `CLAUDE_SESSION_ID` is unset, skip flag writes — the hook is inert without it.

## Step 1 — Readiness gate (BEFORE any code)

```bash
NUM=<issue number>
gh issue view "$NUM" --json title,body,labels,comments
```

Read the issue body **and all comments to the end** before judging readiness. ⚠ Admonition blocks and "Proposed AC changes" subsections in later comments supersede AC checkboxes earlier in the thread — skimming and implementing against stale ACs is a documented failure mode.

Artifacts may live in the body (older issues) or in marked comments (issues filed after 2026-08-09): the latest comment whose first line is `**Research comment — create-issue investigate step**` (investigation) or `**Planning comment — create-issue plan step**` (plan + ACs). A marked comment supersedes a same-topic body section.

| Check | Pass condition |
|---|---|
| Primary source read | If the body cites an external report/thread/email, you opened it (and attachments) before trusting the paraphrase. ⚠ "I can't reach it" isn't a finding until a tool call actually failed. |
| Still-live (issues >30d old, or citing an old report) | Confirm the defect still reproduces on `origin/main` — check-shipped against the report date, not today. |
| Investigation present | research-marked comment or `## Investigation` body section |
| ACs present + sharp | `ac-reviewer` agent returns zero Must-Fix against the current AC set (rubric: `~/.knowledge/modules/shared/records/principles/acceptance-criteria.md`). A verdict only counts against the AC set it reviewed — re-dispatch if the ACs changed since. |
| ACs consistent with investigation | any `Proposed AC changes` in the investigation is already reflected in the current AC set |
| Plan present | planning-marked comment or `## Plan` body section |
| Feature file exists | glob `**/*.feature`, AC-coverage matches the current AC set |

**ALL pass** → tag `planned` if not already, proceed to Step 2.

**ANY fails** → auto-invoke the first missing piece, no asking:
- Missing investigation → `~/.knowledge/modules/shared/records/procedures/github/create-issue/steps/investigate.md`
- Investigation present, plan missing → `~/.knowledge/modules/shared/records/procedures/github/create-issue/steps/plan.md`
- Plan present, feature file missing → `~/.knowledge/modules/shared/records/procedures/github/create-issue/steps/spec.md`

Re-run the gate after each. **Stop (don't guess) when:** ACs are missing/vague and routing to investigate doesn't resolve it; investigation findings would change the ACs (surface the proposed change, wait for the user); the user explicitly paused. Never fabricate a missing section.

**Security findings are owner-only.** Never dismiss, close, or mark as false positive a CodeQL, Dependabot, or secret-scanning alert. If one blocks the PR, fix the code or leave the alert untouched and note it in the PR body under Human verification; only the repo owner dismisses (orchard-codex #458, same decision record).

## Step 2 — Classify and delegate

Classify the issue (label or title keywords): bug / refactor / tech-debt / feature / enhancement.

Delegation routing (`~/.knowledge/modules/shared/records/procedures/codex-meta/delegation-routing/PROCEDURE.md`):

| Task shape | Agent |
|---|---|
| Mechanical, fully-specified, no judgment (bulk rename, boilerplate from exact spec, INDEX updates with explicit mappings) | `fast-coder` |
| Standard implementation with COMPLETE failing tests already written — file count doesn't matter | `coder` |
| Tests absent/incomplete (you must derive behavior), OR passing requires co-designing contracts across 3+ interacting modules, OR root-causing an unknown failure mechanism | `advanced-coder` |
| Writing failing tests from ACs, or reviewing test quality | `test-expert` |

⚠ **Coders never run git or tests.** Brief `coder`/`advanced-coder`/`fast-coder` to build and hand back a structured handoff (pathspecs touched, commit message, proof commands, PR body draft). You (the lead identity) run verification and own git.

⚠ **Never brief "stash if dirty" / "checkout to clean the tree" — in any repo, and above all in `~/.claude`.** `~/.claude/settings.json` is live state: Claude Code reloads its `env` block in every running session, so a stash or checkout that touches it flips the proxy transport under every session on the box (2026-09-04: four sessions stuck on ECONNRESET for 35 min; `mistakes.jsonl` pattern `stash-live-settings-json-under-running-sessions`). Unrelated dirt stays in place; commit your own files by pathspec; if a rebase refuses because of a file you did not change, stop and report.

Isolation: dispatch mutating agents with `isolation: 'worktree'` if more than one will touch the repo concurrently — never two mutating agents sharing one working tree.

## Step 3 — Build loop

- **Tests optimize for shipping speed:** write the minimal tests that get CI green, no more. Verify in one batch run over the whole change when the build is otherwise done — not a red-green-refactor micro-loop per unit.
- **Bugs: reproduce before fixing.** Confirm the failure and its mechanism before writing the fix — don't patch symptoms blindly.
- **Priorities, in order:** simplest fix that actually delivers the AC > clean code (SOLID > CUPID > Clean Code > KISS > YAGNI) > cleverness.
- **Token-conscious briefs:** give the coder exact file paths, exact contracts/interfaces, and the specific failing tests or AC — not the whole issue thread.
- Commit incrementally as work lands — don't hoard an uncommitted pile.
- **Chart PRs: one head per review round** (owner, 2026-09-23, tasks#894). For any PR touching `charts/`: before every push run `helm lint charts/langwatch` and every structural script under `charts/langwatch/tests/*.sh` that `render + assertions` runs (`lifecycle.sh`, `lwql-connection-env.sh`, `stored-objects-upgrade-ordering.sh`, ...), on the touched chart only; they take seconds and each one is a bot finding avoided. The kind e2e stays on CI. Then hold the push until every pending reviewer report for the current head (hygiene, bot, e2e) is in, fix them all, push once. Three consecutive heads on langwatch#8261 each restarted a 35-minute e2e and a bot round for fixes that fit one push. The rule below still holds: the commit exists only when it is pushed, so batch the fixes into one commit, not one commit held back.
- **Every commit is pushed the moment it exists** (owner standing rule, 2026-09-23, Discord 1552124506657656853). `git commit` without an immediate `git push` is a defect; the local branch is never ahead of `origin`. Open the PR as draft as soon as the first commit is up if the work is not review-ready; the push of the last commit is the same turn that runs `gh pr ready`. `enforced_by:` the `guard-push-every-commit-stop.sh` Stop hook (drewdrewthis/orchard-codex#434) — it blocks a turn ending with local commits `origin/<branch>` does not have, except for default branches and agents whose write mandate has no `git.push`.
- ⚠ If you're analyzing for 5+ minutes with zero files written, stop analyzing and write the smallest version that could work.

## Step 4 — Hand off

When convergence reports done, move to REVIEW/QA mode (`${CLAUDE_PLUGIN_ROOT}/skills/ship/references/review-qa.md`). Update the flag file:

```bash
echo '{"pr": null, "phase": "review"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

## Boundaries

- Don't re-plan here — if the plan is missing, that's a gate failure, route to `plan.md`, don't improvise.
- Don't proceed with partial readiness under any deadline pressure.
