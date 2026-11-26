---
name: improve
description: "Make an idea, plan, PR or file better before it runs: stress-test it, simplify it and check it through the matching domain lenses in parallel, then hand back the improved version with a change list. Use when handed an artifact to improve, or before acting on a plan or PR nobody has challenged. Not a critique dump and not a merge gate."
user-invocable: true
argument-hint: "<idea | plan | PR url or number | file path>"
---

# /improve — hand back a better artifact, not a review

Lens registry: `${CLAUDE_PLUGIN_ROOT}/lenses.md`.

## 1. Classify and load

`$ARGUMENTS` is one of:
- **PR** — a URL or number: `gh pr view <ref> --json title,body,files,headRefName` and `gh pr diff <ref>` (`-R owner/repo` when it is not this repo).
- **file** — an existing path: read it whole.
- **plan** — steps or a design toward a goal.
- **idea** — anything else.

Empty → the plan or idea under discussion in this conversation; restate it in one line first.

## 2. Gather context

- Everything the artifact names: files, issues, docs.
- When it changes or concerns a long-running agent: find that agent's workspace (named in the artifact, or where the agent runs), then read its `CLAUDE.md` and `.claude/CLAUDE.md`, the newest two files in its notes dir, and its auto-memory `MEMORY.md` (`ls -d ~/.claude/projects/*<repo dirname>*/memory`; keyed on the git root, `autoMemoryDirectory` overrides). Its conventions bind the improved artifact. Workspace not on this host → put it under owner questions; never guess its rules.

## 3. Pick lenses

Read the registry. Take every `always: yes` lens, plus each lens whose domain the artifact actually touches.

Resolve each `agent` against the agent types your Agent tool lists. Missing or `none` → dispatch `Plan` with that lens's questions.   ⚠ never `general-purpose` — this plugin's guard denies it.

## 4. Run the lenses in parallel

One message, one Agent call per lens. Each brief is self-contained:
- the artifact (full text or diff) and the context paths from step 2;
- the lens's questions;
- "Read-only. Return proposed changes, not critique: each one is the exact edit (replacement text; for a PR, file:line plus patch), why, and its evidence (file:line, doc link, command output). Mark anything only the owner can decide as OWNER."

Wait for every lens before step 5. A lens that fails or returns nothing: say so under Rejected; do not rerun it.

## 5. Synthesize

A lens report is a claim: check any fact a change rests on before accepting it. Accept only changes that serve the artifact's goal. Merge duplicates; when lenses conflict, keep one and reject the other.

Return, in order:
1. **Improved artifact** — the full rewritten idea, plan or file; for a PR, the edits as per-file patch suggestions. Keep the owner's goal and voice.
2. **Changes** — table: change | lens | why.
3. **Rejected** — suggestion — one-line reason.
4. **Owner questions** — only what no lens or file can answer (scope, values, taste, one-way doors), or "none".

# Boundaries

- Never push to, comment on or edit the PR, and never write the file: the caller applies.
- Not a verdict or done-gate, and not execution of the plan.
