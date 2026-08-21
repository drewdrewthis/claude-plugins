---
name: heartbeats
description: "Manage this agent's cron jobs as a directory of markdown unit files — render them into one managed block of the crontab, diff it against what is live, drift-check it, or install it. Use when asked to add, suspend, restore, audit, or install a recurring job, or when asked whether the live crontab still matches its units."
user-invocable: true
argument-hint: "[render | diff | drift-check | install]"
allowed-tools:
  - Read
  - Write
  - Edit
  # Read-only verbs only, enumerated on purpose. What this list means: these
  # three cannot touch a crontab, so they are pre-approved and run without a
  # prompt. `install` is deliberately absent, so it falls through to the normal
  # permission prompt and a human sees the one irreversible operation before it
  # happens. A wildcard over the script would have covered `install --approve`
  # as well and silently removed that prompt.
  #
  # This holds only for an operator whose settings do not already grant
  # something broader. An ambient rule such as Bash(python3:*), or running in
  # bypass-permissions mode, pre-approves `install --approve` no matter what is
  # written here; in that setup the approval gate in the body -- prose, which
  # the model can talk itself past -- is all that remains.
  #
  # The quoting here has to match the invocations in the body character for
  # character or the allowlist misses.
  - Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" render:*)
  - Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" diff:*)
  - Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" drift-check:*)
---

# /heartbeats — cron jobs as unit files

The crontab is generated, never hand-edited. One markdown unit file per job in
the units directory; the script renders them into a single marker-delimited
block. Lines outside the markers belong to whoever put them there.

Units directory resolution, in order: `--units-dir`, `HEARTBEATS_UNITS_DIR`,
then `<CODEX_ROOT or ~/.claude>/heartbeats/units`.

## Operations

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" render        # units -> block text
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" diff          # live block vs rendered
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" drift-check   # 0 iff they match
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/heartbeats.py" install --approve
```

Exit codes: `0` success · `1` error · `2` approval required · `3` drift.

A crontab whose markers are unpaired or duplicated is exit `1` on `diff`,
`drift-check`, and `install` alike — never "no block yet". Report the message to
the person and stop; the repair is theirs to make by hand. Guessing which of two
blocks is live is how the lines between them get deleted.

⚠ `install` without `--approve` is a dry run that exits 2 having written
nothing. Never pass `--approve` on your own initiative — show the person the
`diff` output and get their word first. There is no auto-install.

## Writing a unit

`<units-dir>/<slug>.md`, frontmatter then free prose (the prose is
documentation and is never rendered):

```markdown
---
name: example-daily-report
cron: 30 6 * * *
command: /usr/local/bin/example-job --flag
log: /var/log/example/daily-report.log
enabled: true
---
What this job is for, and what to check when it stops firing.
```

`enabled: false` additionally requires `suspension_reason` and
`restore_condition` — a suspended unit renders as a commented line carrying
both, so it stays visible in the crontab rather than vanishing.

Every field is required, `cron` is exactly 5 fields, and unknown or repeated
keys are rejected. `@reboot`-style nicknames are not supported — write a
5-field schedule. A `cron` value starting with `#` is rejected as well: it
would render a line that crontab reads as a comment, so the unit would install
as an enabled job that never fires.

`cron`, `command` and `log` must escape any `%` as `\%` — cron reads a bare `%`
as newline-plus-stdin and truncates the command there, and a `%` in the
schedule reaches the live line exactly like one in the command. Values carrying
an exotic line-break character (U+2028 and kin) are rejected too: they render
as one crontab line and read back as two.

One bad unit renders nothing at all: a partial block would silently drop the
jobs that failed to parse.

## Steps

1. Edit or add unit files.
2. `render` — the natural first check, and the only operation that cannot touch
   a crontab: it reads the units and prints the block. If a unit is malformed
   you find out here, with nothing at stake.
3. `drift-check` — establish whether the live crontab already diverges from the
   units before your change becomes indistinguishable from the drift.
4. `diff` — show the person exactly what would change.
5. `install --approve` only after they approve.
6. `drift-check` again — exit 0 is the proof the install landed.
