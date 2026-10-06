# REVIEW/QA mode

Convergence reported done. Two gates remain before this can go to a PR: **review** (code quality) and **browser QA** (does it actually work). Neither is optional; browser QA is the hard gate.

```bash
echo '{"pr": <N or null>, "phase": "review"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

If `CLAUDE_SESSION_ID` is unset, skip flag writes — the hook is inert without it.

## Step 1 — Sweep

Before fidelity/quality review, scan the repo for the same pattern or anti-pattern this fix addressed and fix must-fix instances now — don't leave whack-a-mole copies for a later pass. Read and follow `~/.knowledge/modules/shared/records/procedures/planner-orchardist-loop/orchestrate/steps/sweep.md` in `auto` mode.

## Step 2 — Fidelity check

Before quality review, verify each AC actually has evidence (prove-it): re-derive what changed, match it against the AC list, flag anything DROPPED (loop back to convergence to finish it) or DRIFTED/UNVERIFIED (flag and proceed, don't silently drop).

## Step 3 — Review loop

Fan out reviewers in parallel; loop until clean:

- `hygiene-reviewer` — reuse, existing patterns, dead code, bloat, boy-scout rule. "Does this fit the codebase?"
- `principles-reviewer` — SRP, readability, extensibility, simplicity. "Can the next engineer understand this in 30 seconds?"
- Add `security-reviewer` for anything touching auth/PII/secrets/multitenancy filters, `test-reviewer` for test-heavy diffs.

Review methodology (three passes each reviewer applies): (1) line-by-line correctness — bugs, security, multitenancy (`projectId`/`TenantId` filters), API contracts; (2) structural placement — helper location, duplication, layering; (3) design soundness — is this reinventing a dependency's built-in behavior (hits hardest on adapters/wrappers/clients/parsers/retry logic).

Durable artifact: inline `<!-- review-thread -->` comments (resolvable, source of truth) + one upserted verdict comment (`<!-- review-verdict -->` sentinel, `<!-- review-clean: <sha> -->` marker). **NOT-READY iff ≥1 unresolved `<!-- review-thread -->`-tagged inline thread exists.** If fixes are needed: apply them, then re-run fidelity + review scoped `--since <last-clean-sha>` — don't re-review the whole diff.

All gates clean → tag `in-ai-review`, proceed to Step 4.

## Step 4 — Browser QA (HARD GATE)

**No browser proof = not done.** Browser QA against the running app, with screenshots, is the primary proof of done. Unit tests are secondary regression backfill, kept minimal — write only what's needed for CI green.

**No UI ≠ no proof.** There is no test-based exemption. Proof is always from a USER perspective: for a non-UI deliverable, drive the artifact the way its user would and screenshot the USE, not a test run.

**A proof ask is a body edit, not a push.** When the owner or a reviewer asks for proof ("does it work", "show me", "evidence") on a PR, answer by attaching the command output / query result / screenshot to the PR body or a comment — never by writing and pushing a new test. A push for proof restarts CI and stales the review marker; write a test only when the ask says "test" or the AC set already requires one.

- **SDK** — run a real snippet in a terminal against the running app or production; screenshot input + output.
- **MCP server** — invoke the tool from a real MCP client; screenshot the call + result.
- **API** — real request against the running instance (curl/httpie); screenshot request + response.
- **CLI** — run the command; screenshot it.

Pick the surface closest to the truth: production > staging > local running app. Tests remain regression backfill only — a passing test is NEVER the proof.

**Rule: never ask a human for a URL.** Self-boot the app or target production.

Dispatch a `proof-reviewer` agent with the QA brief as the USER-TESTER (it drives the artifact — browser via playwright/MCP for UI, terminal invocation for SDK/API/MCP/CLI — and captures use-proof screenshots itself).

**Proof is per AC, not per PR** (owner, 2026-09-23, tasks#894). The proof-reviewer brief lists every AC from the issue verbatim and the reviewer returns one evidence row per AC: what it ran, on which surface, and the screenshot or output that shows that AC met from the user's side. An AC with an empty row, or a row whose evidence is a test run, is UNPROVEN and the verdict is NOT READY; the lead may not declare READY over it. langwatch#8261 was declared READY with AC1 ("every listed resource is queryable") proven for five of 129 views; the owner found the gap by asking. For chart deliverables, the rows for install, first upgrade from the released chart, and rollback each need their own evidence from a live cluster run (`~/.claude/projects/-home-ubuntu-Projects-langwatch/memory/feedback-chart-review-upgrade-from-main.md`).

### Booting the app (LangWatch project)

- Worktree: `pnpm run dev &`, poll for HTTP 200/302 on `http://localhost:5560`.
- Production fallback: `https://app.langwatch.ai`.
- Full local stack (only when the worktree quick-boot can't cover it — DB-schema/backend changes): `.env` setup, migrations, Redis, seed data, `OPENAI_API_KEY` placeholder. See `~/.knowledge/modules/shared/records/procedures/review-qa/browser-qa/PROCEDURE.md` for the exact commands.
- Test user: `browser-test@langwatch.ai` / `BrowserTest123!` — register via `/api/trpc/user.register?batch=1` if not found.
- **boxd VM alternative** (fast path, ~10s): fork the running golden VM (`boxd fork`), `git checkout` the PR branch inside the fork, Vite HMR serves the new code — confirm HMR landed via `curl` grepping for a unique string you just added, don't assume. Readiness poll `/api/health` (204), not `/` (boxd's proxy 200s on the nginx default page regardless). Teardown: `boxd destroy "$FORK_NAME" -y` for throwaway forks only — never destroy a named non-throwaway fork.

### QA flow

Boot → seed data via script (not clicking through UI) → for each path: navigate → wait_for → click → wait_for → screenshot. Cover happy path + at least one unhappy path. For UI revamps: both color modes and relevant breakpoints. 3-6 screenshots is enough — don't over-shoot.

⚠ Known Playwright MCP traps: stale browser lock (`pkill -f "mcp-chrome-"`), 404s from guessed URLs, portal-based `wait_for` misses, click-via-`evaluate` skips real event handlers (click the element, don't synthesize), cookies set via `evaluate` don't survive navigation, color-mode toggle needs a real click not just `localStorage` writes, modals intercept clicks underneath them, hover-triggered popovers close before the screenshot lands (click the trigger instead), controlled inputs silently no-op on `browser_type` (use React's native input setter + `dispatchEvent`), `aria-disabled` can reflect a stale gate, session cookies die on `NEXTAUTH_SECRET` regen.

### Publishing screenshots — MANDATORY, before reporting ready

Never commit screenshots to the working repo (`enforced_by:` `pr-ready-check` C6's file-list check — an added image on a proof/screenshot/evidence path outside `langwatch/pr-screenshots` is NOT READY). This includes non-UI proof: a rendered-config or terminal-output PNG goes to pr-screenshots under `branch-<slug>/` exactly like a browser screenshot — never committed alongside the change it proves. **MONITOR mode owns PR creation** — this mode never opens the PR, only stages screenshots keyed by branch.

```bash
cd ~/Projects/pr-screenshots && git pull --rebase
mkdir -p branch-<slug>/<section>
cp <screenshot> branch-<slug>/<section>/<name>.png
git add branch-<slug>/<section>/<name>.png
git commit -m "screenshots: <slug> <section>" && git push
```

Raw URL (pre-PR): `https://raw.githubusercontent.com/langwatch/pr-screenshots/main/branch-<slug>/<section>/<name>.png`. Do NOT embed these yet — `monitor.md` Step 1 claims the `branch-<slug>/` dir as `pr-<N>/` and embeds the raw URLs in the PR body at PR-open.

### Done criteria (all must be yes)

- Booted the app yourself or targeted production — never asked a human for a URL.
- Navigated like a real user (not just hit an API).
- Tried at least one unhappy path.
- Screenshots of happy path + edge case captured.
- Both color modes / relevant breakpoints for UI work.
- Screenshots pushed to `pr-screenshots` under `branch-<slug>/`, ready to embed at PR-open.
- Noticed and fixed (or filed) at least one rough UX edge.

## Step 5 — Hand off

```bash
echo '{"pr": <N or null>, "phase": "browser-qa"}' > "/tmp/claude-ship-flow-$CLAUDE_SESSION_ID"
```

Proceed to `${CLAUDE_PLUGIN_ROOT}/skills/ship/references/monitor.md`.
