# Contributing

This repo ships **machinery only** — plugins installed into agent sessions
(`procedures`, `about-my-person`, `take-note`). Generated knowledge (records,
notes, ABOUT_MY_PERSON.md) lives on the host under `~/.claude/references/**`
or `~/workspace/**`, never in this repo. If a change would write a record
file here, it's in the wrong place.

## Standards

Vendored from the codex, binding on every change here — read them, don't ask
this doc to restate them:

- [`docs/principles/coding.md`](docs/principles/coding.md) — design priority
  SOLID > CUPID > Clean Code > KISS > YAGNI; comments explain WHY not WHAT;
  boy-scout rule.
- [`docs/principles/delegation.md`](docs/principles/delegation.md) — agent
  selection and communication registers, where relevant to authoring flow.
- [`docs/principles/agent-facing-docs.md`](docs/principles/agent-facing-docs.md)
  — how to write `SKILL.md` and agent `.md` prose: completeness is the
  floor, not-one-token-longer is the ceiling.
- [`docs/principles/clean-up.md`](docs/principles/clean-up.md) — leave the
  tree cleaner than found; no stray scratch files, no dead references.

## Vendoring rule (`plugins/procedures`)

The procedures plugin's machinery (skills, `procedure-scout`/`work-reviewer`
agents, gate hooks + lib, `query-records.sh`, `log-record.sh`, linter,
templates) is vendored from `orchard-codex@develop-sweatshop`.

- Anything that isn't upstream must be marked `# PLUGIN ADAPTATION: <why>` at
  the point of divergence — the plugin-hosting context (data-root defaults,
  `${CLAUDE_SKILL_DIR}` script paths) and harness dispatch-path differences
  (the fork-skill `model:` pin) are the only legitimate reasons to diverge.
  See `README.md`'s documented adaptation classes for the pattern; adding a
  divergence means adding its class there in the same PR.
- Everything else stays byte-close to upstream. A re-sync from
  `develop-sweatshop` should be a small, reviewable diff — don't introduce
  unmarked drift, even a reformat or a "while I'm here" rename.

## Tests are the gate

```
cd plugins/procedures && bats hooks/tests
```

Must be green before any PR merges. New hook or script behavior — including
a marked adaptation — needs a bats test added in the same PR, not a
follow-up.

## Reviewers

Repo-local agents in `.claude/agents/`: `principles-reviewer`,
`hygiene-reviewer`, `security-reviewer`, `test-reviewer`. Run the ones
relevant to your diff before opening a PR — a hook/script change wants all
four; a docs-only change wants `principles-reviewer` at minimum.

## Design rules for new machinery (ADR-001)

Adding a hook, script, or skill to `plugins/procedures` (or a new plugin)
follows the taxonomy in
[`docs/adrs/001-procedural-knowledge-system.md`](docs/adrs/001-procedural-knowledge-system.md):

- **One responsibility per hook/script, stated in its header.** No hook
  that both gates and writes a record.
- **Hooks fail open, and record blind fail-opens.** A gate that blocks on
  its own bug bricks the session — missing dependency or unreadable state
  releases the gate, and every such release is logged.
- **Skills are thin gateways.** Logic lives in scripts or a dispatched
  agent, never in `SKILL.md` prose — a skill is the invocation handle, not
  the implementation.
- **Data roots default to `~/.claude`, env-overridable via `CODEX_ROOT`**
  (or the per-script var). Installed as a plugin, a script must not write
  into the plugin directory itself.
- **No host-specific identity or paths baked into shared code.** Anything
  tied to one box or one person's layout is a config default, not a
  literal.

## Branch / PR flow

- Feature branch off `main`.
- PR review required — no direct pushes to `main`, no force-pushes.

## Versioning — automated, never by hand

Installed plugins are cached per version at
`plugins/cache/<owner>/<plugin>/<version>/`. A change that ships without a
version bump **never reaches an already-installed box** — it merges, and every
existing install keeps running the old copy.

`release-please` owns every `plugins/*/.claude-plugin/plugin.json` version.
Do not edit those `version` fields by hand — a manual bump collides with the
release PR.

What you do instead: **write a conventional-commit subject**, since that is what
picks the next version.

| Prefix | Bump |
| --- | --- |
| `fix:` / `perf:` | patch |
| `feat:` | minor |
| any type with `!` (e.g. `feat(procedures)!:`) or a `BREAKING CHANGE:` footer | major |
| `chore:` / `docs:` / `test:` | none — **ships nothing to installed boxes** |

Scope by plugin (`fix(procedures): …`) so the release lands on the right one;
each plugin versions and tags independently as `<plugin>-v<version>`.

⚠ A behaviour change committed as `chore:` or `docs:` produces no release and
therefore no bump — so it stays invisible to every installed box. If a change
should reach users, it is a `fix:` or a `feat:`.
