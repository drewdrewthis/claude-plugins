# LAUNCH mode

You're starting a fresh worker/session to work an issue. Default LOCAL (this machine) unless the user asked for the remote sweatshop VM.

## Steps

1. **Concurrency pre-flight.** Check existing work on the issue before spawning anything — a duplicate worker is wasted spend.
   - Use `~/.claude/scripts/session-truth --all` (the only trustworthy concurrency check). Never rely on daemon-count, regex-filter, or bare-pane checks — all documented-broken.
   - Existing-work check: GraphQL timeline on the issue + open-PR search + (optional) failing-test-signature grep. Any hit → **stop**, recommend driving the existing PR instead of spawning a new worker. Never auto-close it.

2. **Resolve issue + names.**
   ```bash
   NUM=<issue number>
   gh issue view "$NUM" --json title,body,labels
   ```
   - Branch: `issue<N>/<slug>`
   - Worktree dir: `.worktrees/issue<N>-<slug>`
   - tmux session name: slot-token `<slot>-<repo>_issue<N>` where slot ∈ {bug, feat, drive, devtool} — one item per slot, check occupancy first. Underscores for governor names, hyphens for sisters/helpers, no colons.

3. **Authorship gate** (HARD STOP before any push): if a PR already exists for this issue and its author isn't the fleet/owner identity, stop — do not push over someone else's PR.

4. **Create the worktree.**
   ```bash
   mkdir -p .worktrees
   git worktree add ".worktrees/issue${N}-${SLUG}" -b "issue${N}/${SLUG}" <base-branch>
   ```
   Ensure `.worktrees/` is gitignored. Copy `.env` files into the new worktree and **verify by checking file presence AND value length** — don't trust a hook's claim that it copied them.

5. **Spawn the tmux session.**
   ```bash
   source ~/.claude/fleet.env   # FLEET_MODEL, FLEET_EFFORT — never hardcode
   tmux new-session -d -s "<NAME>" -x 200 -y 60 -c "<WORKTREE_ROOT>"
   tmux send-keys -t "<NAME>" "claude --name '<NAME>' --dangerously-skip-permissions --model $FLEET_MODEL --effort $FLEET_EFFORT" Enter
   sleep 12; tmux capture-pane -t "<NAME>" -p | tail -30
   ```
   The pane's owning process is a shell, not claude — a claude exit returns to a prompt instead of killing the session.

   CWD is always the worktree root, never a subdirectory. `--agent lead` bakes in model/effort — don't also pass `--model`/`--effort` when using it.

   **Verify auth before sending the directive:**
   | Pane shows | Meaning | Action |
   |---|---|---|
   | `Welcome to Claude` + cursor | OK | proceed |
   | `Retrying in Ns` | broken | stop, escalate |
   | `/login` URL | needs auth | extract URL, send to user |
   | `API Error: 401` | needs auth | same as login |
   | permission dialog | wrong flags | relaunch with `--dangerously-skip-permissions` |
   | `Resume previous session?` picker | stale state | send `q` + Enter, then the directive |

   ⚠ The status bar's `👤 user@email` is NOT proof of auth — only the states above are.

6. **Send the directive and verify landing.**
   ```bash
   tmux send-keys -t "<NAME>" "read and follow ${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md, IMPLEMENT mode, for issue #<N>" Enter
   sleep 3 && tmux capture-pane -t "<NAME>" -p | tail -10
   ```
   ⚠ `send-keys -l` with a long string (~1200 chars) silently drops all but the tail — the worker then replies "message truncated". Send directives in chunks of ≤250 chars, `sleep 0.5` between `send-keys -l` calls, then `Enter`, then a second `Enter` after ~3s. Confirm landing with `capture-pane` showing the spinner/`esc to interrupt`, not just "no error".

7. **Report** the session name, worktree path, and issue number back to whoever asked you to launch.

8. **Retiring or replacing a session.** Before `tmux -L default kill-session -t <NAME>`, check nobody is viewing it: `tmux -L default list-clients -F '#{client_tty} -> #{client_session}'` (and `#{session_attached}`). Default `detach-on-destroy on` DETACHES a client whose session is destroyed — in a nested outer shell this kills the inner attach pane ("Pane is dead"). Mitigation until orchardist #796 ships: `tmux -L default set -g detach-on-destroy off` once per server.

   **Merge confirmation before cleanup.**
   - Confirm the merge via git plumbing, not `gh api`, before any cleanup: `git ls-remote --heads origin <branch>` returns empty AND `git fetch origin main && git log -1 origin/main` shows the merge commit.
   - Don't trust `gh api rate_limit` as authoritative — a 403 on an actual call overrides a healthy-looking `remaining` count; fall back to git plumbing.
   - Never chain `kill-session`/`worktree remove`/`branch -D` in the same `&&` command as a `git fetch` or other remote-hitting call — run the merge, confirm via git plumbing, THEN run cleanup as a separate command.

## Stuck worker recovery

A session failing repeatedly with `API Error: 529/500` for >15 min while siblings progress is usually poisoned by an oversized first request (e.g. `/ship CONTINUE` over a large uncommitted diff). Recovery that worked: dispatch an `advanced-coder` subagent to finish/verify the code in the worktree (no commits), then kill the session and start a fresh one whose directive is only the small commit/rebase/push/PR steps.

## Health monitor classification

Claude Code panes show three "working" shapes — match all three before treating a pane as idle:
- spinner with hint: `✻ Whirring… (… · esc to interrupt)`
- spinner without hint: `✢ Vibing… (41m · ↓ 13k tokens)`
- agents-panel tree: `⏺ main` / `◯ advanced-coder  …`

Only nudge on `API Error` found within the last ~8 non-blank lines.

## Instrumentation note

Nothing to configure. LangWatch OTel instrumentation is already global via `settings.json` env vars — every spawned session is auto-instrumented. Do not add per-session tracing setup.

## Sisters, not children

Spawn siblings with `tmux new-session`, never `tmux new-window` off another session — a parent-session death would cascade and kill children spawned as windows.
