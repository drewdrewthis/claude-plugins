# PR + MONITOR mode

<!-- PLUGIN ADAPTATION (owner-directed, drewdrewthis/claude-plugins#186): the readiness-check path, the C1–C9 un-draft gate, the quoted-verdict ready report, and the REST watcher fallback diverge from orchard-codex@develop-sweatshop skills/ship. -->

Open the PR, arm a watcher immediately, drive to green. The session that opens the PR owns watching it until it's ready — don't hand that off and walk away.

```bash
echo '{"pr": <N>, "phase": "monitor"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

If `CLAUDE_SESSION_ID` is unset, take the id from the tasks path (`/tmp/claude-1000/<project>/<session-id>/tasks/`) and write the file explicitly. Do not write `/tmp/claude-ship-flow-` with an empty suffix — nothing reads it.

The statusline reads this file too: `.pr` drives the PR link line (it wins over the harness's cached PR detection, which lags branch switches), and optional `.issues: [N, ...]` / `.prs: [N, ...]` add link lines for anything else the session is tracking. Keep them current when the PR under work changes.

⚠ `ralph-loop` is **disabled**. Do not invoke `/ralph-loop:ralph-loop` or reference it. Use the Monitor tool + a direct iteration loop instead — this file replaces that mechanism.

## Step 1 — Open the PR and arm the watcher

**MONITOR mode owns PR creation** — REVIEW/QA never opens a PR, it only stages screenshots under `branch-<slug>/`.

Open as draft or ready per repo convention (`gh pr create`) to get the PR number `<N>`. Then:

1. Claim the staged screenshots:
   ```bash
   cd ~/Projects/pr-screenshots && git pull --rebase
   git mv branch-<slug> pr-<N>
   git commit -m "screenshots: claim pr-<N>" && git push
   ```
2. PATCH the PR body to the write-pr format (`~/.knowledge/modules/shared/records/procedures/github/write-pr/PROCEDURE.md` — must include the `## Human verification` and `## How I can prove I was successful` headings), embedding the raw URLs: `https://raw.githubusercontent.com/langwatch/pr-screenshots/main/pr-<N>/<section>/<name>.png`. The body is a living doc: on each significant push/fix, refresh the top status + screenshots in place rather than appending, folding history in `<details>`.
3. Immediately arm a watch via the **Monitor tool**, `persistent: true`, `timeout_ms: 3600000`. Run `ls ~/.claude/tooling/orchardist-watch/pr.sh` first and use the line that exists on this box:
   ```bash
   # orchard-codex host:
   ~/.claude/tooling/orchardist-watch/pr.sh <owner>/<repo> <N>
   # any box without that script (e.g. drew-sweatshop) — REST only; `gh pr checks` is GraphQL, never poll it:
   source ~/Projects/langwatch-sweatshop/modules/github/scripts/lib/gh-checks-rest.sh
   sha=$(gh api repos/<owner>/<repo>/pulls/<N> --jq .head.sha)
   while fetch_checks_rest <owner> <repo> "$sha" | jq -e 'length == 0 or any(.[]; (.status // "COMPLETED") != "COMPLETED" or .state == "PENDING")' >/dev/null; do sleep 30; done
   fetch_checks_rest <owner> <repo> "$sha" | jq -r '.[] | "\(.conclusion // .state)\t\(.name // .context)"'
   ```
   `pr.sh` is session-length: it watches CI checks, new comments, review threads, and pushes. The REST fallback watches CI only and is NOT session-length — it waits until every check on that one head sha has finished, then prints one `<conclusion> <name>` line per check and exits. A line that does not start with `SUCCESS`, `SKIPPED` or `NEUTRAL` is a failed check; no lines at all means the fetch failed — re-arm. Re-arm it after every push, because the sha changed. Pass Logic C is your only review-thread signal there, so run it every iteration — after the fallback exits, keep iterating Step 2 yourself until the readiness check prints `overall: READY`; do not idle waiting for an event. Verify the watch armed within ~30s (baseline line or `WATCH-DEGRADED` for `pr.sh`; a running Monitor task for the fallback) — don't assume it did. On a fallback box, `monitor_armed: true` (below) means a watch is running, or the last one ended with every check finished on the current HEAD.

Once verified alive, mark it in the flag:

```bash
echo '{"pr": <N>, "phase": "monitor", "monitor_armed": true}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

If the Monitor is later stopped before `done` (e.g. to fix something inline), set `"monitor_armed": false` (or drop the key) until it's re-armed — the Stop hook checks this key while `phase: monitor`. The same applies on the fallback when the watch printed a failed check or belongs to an older HEAD: set `false` until you re-arm after the fix push.

## Step 2 — Iteration loop (replaces ralph-loop)

Each iteration, run Pass Logic Steps A–G below, then re-check `pr-ready-check.sh`. Loop until READY or MERGED. **Anti-wedge rules:**
- Commit incrementally every iteration you touch code, and **push every commit immediately** — `origin/<branch>` must equal `HEAD` at the end of every turn (owner standing rule 2026-09-23). Unfinished work lives in a draft PR on the remote, never only on the box.
- If analyzing >5 min with 0 files written, stop and write the smallest fix.
- Don't delegate the whole task to one sub-agent — you (this session) own conflict resolution and final commits; delegate discrete pieces.
- Bound any wait on a code-quality bot to ~15 min.
- **Stop at ready.** Don't keep re-verifying past a clean `pr-ready-check.sh` result.
- Rate-limit errors are never blockers by themselves — check GraphQL vs REST bucket separately: `gh api rate_limit`.

### Pass Logic

**Draft gate (used by D, F):** grep the workflow for a `ready_for_review` trigger (`grep -n draft .github/workflows/*.yml`). No such trigger → `gh pr ready` won't re-trigger the gated jobs — don't draft, just remove reviewers and push. Has one → undrafting spawns a fresh run of the gated job, and a pre-ready green does NOT cover it; after `gh pr ready`, verify the NEW run by its own run id (known false-green: `langwatch/langwatch#7611`, `docs-ci.yml`'s `check_generated_files` job). Before `gh pr ready` on a repo with a `ready_for_review` trigger, run the draft-skipped job's full command locally (the whole test suite, not the touched subdir) — the undraft run is the first time it executes on CI.

**A — Locate.** `gh pr view <N>` is your only GraphQL call per iteration; everything else uses REST.

**B — Rebase if needed.** `git fetch` + merge-base check against base branch; if behind, `git rebase` + `push --force-with-lease`, then exit this iteration (let CI restart clean).

**C — Unresolved review threads.** Paginated GraphQL query for `isResolved == false && isOutdated == false`. If a code-quality bot's findings are still landing, wait inline capped at ~15 min — never exit while a known bot pass is still in flight.

**D — Triage/address comments.**
1. Check the draft gate first (above) — is the PR still draft? Handle accordingly.
2. Classify each comment: AC-changed (**pause**, surface to user), AC-proposed-but-not-ratified (apply without pausing), AC-adjacent (delegate to `coder` + prove-it + review), comment-scoped (fix / YAGNI / won't-fix — classify explicitly).
3. After addressing: run the verification battery → commit → push → reply to each thread → resolve threads.
   - Bot threads: don't resolve manually — let the bot self-resolve, except a narrow documented carve-out.
   - Human threads (any human author, the repo owner included): after the fix commit is pushed and the reply posted, the worker resolves the thread itself via the GraphQL mutation. Never park a PR waiting for the owner or reviewer to resolve a thread you already addressed — that wait is a D.3 breach (orchard-codex #456, decision 2026-09-24-night-watch-direction-defaults-threads-suite-codeql).
   - Verification battery means the targeted checks for the files you touched, then push and let CI run the full suite. Never run the repo's full test suite, full lint, or full typecheck locally on a langwatch PR — CI is the authority, and a local full-suite run is wasted time (orchard-codex #457, decision 2026-09-24-night-watch-direction-defaults-threads-suite-codeql).
4. Exit the iteration.

**E — CI check.** Use REST (`~/Projects/langwatch-sweatshop/modules/github/scripts/lib/gh-checks-rest.sh` `fetch_checks_rest`). If pending, wait inline — **never exit while CI is pending.** Cross-check githubstatus.com before treating a stall as your bug (provider outage short-circuit). The armed watcher (Step 1, item 3) IS the CI wait: never start a second poll loop and never block a turn on a full-CI wait — react to the first `conclusion=failure` event it emits (a per-check event arrives minutes before `CI DONE`). On the REST fallback, a printed line that does not start with `SUCCESS`, `SKIPPED` or `NEUTRAL` is the failure signal.

**F — CI failure.** Check the draft gate (above), cross-check `gh run list` for the real failure, diagnose, fix, commit, push, exit.

**G — Cross-check and finalize.**
1. Verify shard tally — green checks are forgeable: `~/.claude/scripts/verify-ci-shard-tally.sh <owner>/<repo> <N>` (exit 1 = green unverified; must see a `Test Files N passed` tally line). `ls` the script first: where it is absent (e.g. drew-sweatshop) G.1 cannot run — say so in the PR body, do not claim the shard tally was verified, and treat C2 of the readiness check as the only CI gate.
2. Verify both typecheck steps ran if the repo splits them (LangWatch: `pnpm typecheck` AND `pnpm run typecheck:tests`).
3. Finalize: PATCH the PR body (write-pr format), `gh pr ready`, assign, request reviewers, set the `pr-ready` phase label (`records/procedures/github/scripts/tag.sh -R <owner/repo> pr-ready <issue> <N>`).
   **Ship's terminal state is human-review-ready: non-draft, assigned, reviewers requested.** Un-drafting is the shipping worker's own action, gated on every criterion of `pr-ready-check` (C1–C9), not a subset: before `gh pr ready`, run the Step 5 item 1 command and un-draft only when its single `FAIL` line is `C1: PR is a draft` (the script fails C1 on every draft). Then re-run it and require `overall: READY` — that re-run is the Step 5 run. No fleet role (orchardist, assistant, planner) gates it, and "await the owner's un-draft" is not a ship step. The only reason to leave a green, proven PR in draft is an explicit owner instruction recorded on that PR. (Owner ruling 2026-09-08 on langwatch/langwatch#7959, which sat done-but-draft for half a day waiting on a gate nobody owned.) **Draft is only for not-yet-finished work: the PR flips to ready in the same turn that pushes the last commit** — not after a bot round, not after a wait, not on a later beat (owner standing rule 2026-09-23, Discord 1552124506657656853).
4. Verify the Monitor is still alive (`pr.sh`), or that the last REST fallback watch ended with every check finished on the current HEAD.
5. Only THEN consider emitting a completion signal — see Step 5.

### Verification discipline (every state-changing action gets re-fetched, not trusted)

| Action | Re-verify by |
|---|---|
| `git push` | check `headRefOid` changed |
| PR body PATCH | re-fetch, check first 100 chars |
| `gh pr ready` | re-fetch, check `draft == false` |
| add reviewer | check `requested_reviewers` actually contains them |
| thread resolve | re-query `isResolved` |

### Known silent failures — check for these, don't assume success

- Draft-gated checks report `SKIPPED`, not passing — don't count them as green.
- `@file` literal-string bug in some comment-posting paths.
- `git push` silently rejected by a hook.
- `gh pr ready` fails silently on branch protection.
- Adding a reviewer succeeds even if they're not actually in the review pool.
- Thread-resolve mutation can hit a stale node id and no-op.
- `force-with-lease` can reject on stale info even when your rebase was correct — re-fetch and retry once.
- A stray background `vitest`/`tsc` process can contaminate your local validation — kill stragglers before trusting a local run.
- `gh` JSON fields `headRefSha` / `merged` are invalid — use `headRefOid` / `state` + `mergedAt` + `mergedBy` + `mergeCommit`.
- Pin `origin/main`'s sha once before comparing across calls — it moves.
- Squash-merge ancestor checks need the right geometry — don't assume a simple `git merge-base --is-ancestor`.

## Step 3 — Terminal check: `pr-ready-check.sh`

```bash
~/Projects/langwatch-sweatshop/modules/github/scripts/pr-ready-check.sh <owner> <repo> <N>
```

The script lives in the https://github.com/drewdrewthis/langwatch-sweatshop toolkit, not in this plugin. (Also `just pr-ready` in the toolkit, where `just` is installed.) Exit code of the bare command: 0 = `READY` or `MERGED`, 1 = `NOT_READY`, 2 = `ERROR` — a pipe into `jq` or `grep` hides it, so read `overall` there. If the path is missing on your box, that is a blocker to report — do not substitute your own reading of the criteria.

This is the single source of truth — 9 criteria (C1–C9): open/non-draft/mergeable; CI green (supersede-aware; the shard tally is the separate G.1 script); review verdict READY at HEAD by a known reviewer; zero unresolved review signals (threads AND top-level comments, outdated-but-unresolved still counts as blocking); write-pr format present (`## Human verification` + `## How I can prove I was successful`); use-proof embedded (no backend-only exemption — non-UI surfaces prove via real invocation screenshots); no unfiled deferments; merged short-circuits to done; a raw capture from the running app in the proof section (C9: an HTTP status line, a `$ cmd` line with its output, or a linked `.txt`/`.log` — images alone do not pass; a UI-only PR declares `<!-- ui-only -->`).

⚠ No criterion reads `reviewDecision` directly — cross-check separately: `gh pr view <N> --json reviewDecision,mergeStateStatus`. `REVIEW_REQUIRED` blocks as hard as `CHANGES_REQUESTED`. The merge gate is the **union** of branch protection AND repository rulesets — check both.

```bash
~/Projects/langwatch-sweatshop/modules/github/scripts/pr-ready-check.sh <owner> <repo> <N> | jq '{overall: .overall, failed: [.criteria[] | select(.passed != true) | .id]}'
```

Callers MUST test `overall == "READY"` (or `"MERGED"`) positively — never `overall != "NOT_READY"`.

## Step 4 — Never claim ready on pending/failing CI

Pending CI obligates you to keep watching to a terminal conclusion — never hand off, never claim done, while any check is FAILING or PENDING. A red base branch is still red for you; don't present an inherited failure as fixed. State CI state out loud on any handoff.

## Step 5 — Set `done` only when both are true

1. This command, run at the current HEAD, prints `overall: READY ✓` (or `overall: MERGED ●`). Keep the output — the report quotes it.
   ```bash
   ~/Projects/langwatch-sweatshop/modules/github/scripts/pr-ready-check.sh --format text <owner> <repo> <N> 2>&1 | grep -E '^overall:|^  FAIL|^ERROR|^error:|No such file'
   ```
2. Browser proof (or documented no-UI-surface exception) is embedded in the PR body.

```bash
echo '{"pr": <N>, "phase": "done"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

Only then report ready/done to whoever is waiting on this.

**The ready report quotes the verdict.** Paste the output of the command in item 1 into the report:

- `overall: READY ✓` or `overall: MERGED ●` → quote that line. That is a ready (or merged) report.
- No `overall:` line (script missing or crashed), or `overall: ERROR` → report BLOCKED and quote the `ERROR`/`error:`/`No such file` line, or say the command printed nothing. Do not set `done`.
- `overall: NOT_READY ✗` → quote it with every `FAIL` line, and report not ready. Do not set `done`.

A ready report without the quoted `overall:` line is not a ready report: the receiver treats it as not ready. Green CI is one criterion (C2) of nine — it is never the verdict.
