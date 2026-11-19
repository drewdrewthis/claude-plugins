---
name: task-list
description: Keep your running task list so no ask is dropped. Use the moment you get an ask, a plan step or a sub-agent job; when you finish, block or drop one; before you stop with work open; and when the turn watcher or a "[task ping]" reminds you.
---

# Task list

Your context can be lost; this list is not. The command is `~/.claude/hooks/checker/task.sh` (from dotclaude). It writes `~/.local/state/tasks/<your agent name>.jsonl`. `task.sh help` lists every command.

1. **Add it the moment you get it.** Every ask from a person, every step of a plan you made, every sub-agent or background job you start:
   `task.sh add "<what, for whom, done when>" --from <link or quote>` (add `--owner` for your owner's own ask). It prints the id (T1, T2, ...).
2. **Move it as you work.**
   - `task.sh start <id>` when you begin.
   - `task.sh done <id> --proof <link or output>`: only with proof you saw.
   - `task.sh block <id> --on <who or what>`: a named blocker. Then go to the next open task.
   - `task.sh drop <id> --why <reason>`: an `--owner` task also needs `--owner-ok <link to the owner's OK>`.
3. **Before you stop**, run `task.sh list`. Every open task needs one of:
   - a named blocker (`block`), or
   - a revival ping: `task.sh ping <id> --in 30m` (or `--at <time>`). It sets a local wake that types `[task ping] <id>: ...` into your own session (Rush, else tmux). Nothing goes to Laze. If it says there is no local wake for this session, use the follow-up-later skill.
4. **When a `[task ping]` or the watcher's "Task list" reminder arrives:** work the next open task, or block, ping or close it. After 3 reminders with no change to your list, tell your owner which task is stuck and why, then stop.

There is no hard block: you can stop. The turn watcher reads the list after each stop and wakes you if a task is open with no future ping and no blocker.
