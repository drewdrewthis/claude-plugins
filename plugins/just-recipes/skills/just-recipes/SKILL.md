---
name: just-recipes
description: Use when running project commands/tasks in a repo that has a justfile, when the user says "just", "recipe", "run the deploy/test/build task", or before composing an ad hoc shell command that a recipe likely covers. Prefer named just recipes over ad hoc shell.
---

# just-recipes

## Steps

1. **Discover before composing.** Run `just --list` (and `just --list --list-submodules` if the justfile mounts modules) before writing any ad hoc shell command. If a listed recipe covers the intent, use it instead of assembling the equivalent shell yourself.
2. **Unfamiliar recipe → inspect first.**
   - `just --show <recipe>` — print its definition without running it.
   - `just --dry-run <recipe>` — print the commands it would run without executing them.
3. **Run it.**
   - `just <recipe> [args...]`
   - Module recipes: `just <module>::<recipe>` (e.g. `just global::deploy`).
4. **Machine-readable introspection**, when you need the full recipe set/structure programmatically:
   - `just --dump --json`
   - `just --summary`
5. **Global/shared library convention.** A project justfile may mount a shared recipe library via `mod global '<path>'` (the path is per-machine — never hardcode a home directory path) and enable `set fallback` so recipes not found locally resolve from a parent directory's justfile. Expect these when a repo's own `just --list` looks sparse.

## Authoring conventions (when asked to add or edit a recipe)

- Name in lowercase kebab-case with an explicit verb (`build-image`, not `image`).
- Destructive actions must look destructive in the name: `kill-session`, `delete-server`, `drop-db` — never a bare noun or euphemism.
- Keep recipes thin: nontrivial logic goes in a script the recipe calls, not inline in the justfile.
- Add a doc comment line directly above each recipe — `just --list` surfaces it.

## Boundaries

- Never run a destructive-named recipe (`kill-*`, `delete-*`, `drop-*`, etc.) without explicit user instruction for that specific action.
- `--list`, `--show`, `--dry-run`, `--summary`, `--dump` never execute recipe bodies — safe to run freely for discovery.
