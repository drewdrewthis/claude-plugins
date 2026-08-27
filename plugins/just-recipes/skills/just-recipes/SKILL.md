---
name: just-recipes
description: Use when running project commands/tasks in a repo that has a justfile, when the user says "just", "recipe", "run the deploy/test/build task", or before composing an ad hoc shell command that a recipe likely covers. Prefer named just recipes over ad hoc shell.
---

# just-recipes

## Enforcement model

- A PreToolUse hook denies raw Bash wherever a justfile resolves from the project dir. Discover recipes with `just --list`; escape hatch: `just wrap "<cmd>"` — runs the command under timeout/output-cap guardrails and logs it to `$CODEX_ROOT/state/wrap.log`.
  ⚠ fm.just-wrap-unwired — bare `just wrap` errors ("no such recipe") in any project whose own justfile lacks `wrap`: mounted module recipes stay namespaced and `set fallback` walks parent directories, not modules (verified on just 1.58.0). Always-resolving form: `just --justfile ~/.claude/just/justfile -d . wrap "<cmd>"` (`-d .` pins execution to the current dir). After the wiring below, `just global::wrap "<cmd>"` also works.
- One-time project wiring — add to the project justfile to expose every global recipe as `global::<recipe>`:

  ```just
  mod global '~/.claude/just/justfile'
  set fallback
  ```

- Parsing: commands are trimmed of surrounding whitespace, then segmented on shell control operators (`&&`, `||`, `;;`, `;`, `|`, newlines — quoted or backslash-escaped operators don't split). A lone segment passes when its first word is `just` or a read-only verb (`cd`, `pwd`, `echo`, `ls`, `cat`, `command -v`, `which`); a multi-segment command passes only when EVERY segment is a `just` invocation. Command substitution (`$(...)`, backticks) is denied wherever the hook enforces.
- Kill switch: `JUST_RECIPES_ENFORCE=off` (or `0`) disables enforcement. Repos without a resolvable justfile and machines without `just` pass everything through.

## Habit loop

Friction from a denied/wrapped command → write a script → add a recipe calling it, with a doc comment → discoverable via `just --list`. `just wrap-report` summarizes wrap.log — treat it as the recipe backlog.

## Flat-recipe convention

One kebab-case recipe per intent, flat namespace. Chooser stubs (e.g. `just log` printing which log-* recipes exist) are cheap — add them freely.

## Steps

1. **Discover before composing.** Run `just --list` (and `just --list --list-submodules` if the justfile mounts modules) before writing any ad hoc shell command. If a listed recipe covers the intent, use it instead of assembling the equivalent shell yourself.
2. **Unfamiliar recipe → inspect first.**
   - `just --show <recipe>` — print its definition without running it.
   - `just --dry-run <recipe>` — print the commands it would run without executing them.
3. **Run it.**
   - `just <recipe> [args...]`
   - Module recipes: `just <module>::<recipe>` (e.g. `just global::deploy`).
4. **Machine-readable introspection**, when you need the full recipe set/structure programmatically:
   - `just --dump --dump-format json`
   - `just --summary`
5. **Global/shared library convention.** A project justfile may mount a shared recipe library via `mod global '<path>'` (the path is per-machine — never hardcode a home directory path) and enable `set fallback` so recipes not found locally resolve from a parent directory's justfile. Expect these when a repo's own `just --list` looks sparse.

## Authoring conventions (when asked to add or edit a recipe)

- Name in lowercase kebab-case with an explicit verb (`build-image`, not `image`).
- Destructive actions must look destructive in the name: `kill-session`, `delete-server`, `drop-db` — never a bare noun or euphemism. This naming is authoring guidance, not a safety check (see Boundaries).
- Keep recipes thin: nontrivial logic goes in a script the recipe calls, not inline in the justfile.
- Add a doc comment line directly above each recipe — `just --list` surfaces it.

## Boundaries

- Never run any recipe that may mutate or delete data or infrastructure without explicit user instruction for that specific action — judge by what the recipe does, not by whether its name looks destructive; an innocuous name is not a safety signal.
- `--list`, `--show`, `--dry-run`, `--summary`, `--dump` skip recipe bodies, not recipe files: top-level backticks, `shell(...)`, and `dotenv-command` can still evaluate during discovery. Not universally side-effect-free — read the justfile for these before treating discovery commands as inert.
