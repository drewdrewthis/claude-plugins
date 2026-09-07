---
id: std.record-admissibility
kind: standard
date: 2026-09-05
keywords: [commit-records, check-sanitization, check-sections, lint-frontmatter, build-record-index, librarian, admissibility, gate, duplicate-id, case-twin, size-cap]
links: { standards: [std.record-frontmatter], principles: [], adrs: [] }
status: active
title: Record Admissibility
description: The deterministic gate every record must clear before a librarian commit lands in a knowledge store.
---

# Record Admissibility

This is the single source of truth for the **deterministic admissibility gate**
run by `scripts/commit-records.sh` before any record is committed into a
knowledge-store repo. The scripts cite this file; they do not re-describe the
rubric. No rule here calls a model or the network — the whole gate is
headless bash.

The gate is about **shape and safety, never truth**. Contradictory records are
allowed. The gate never reconciles meaning; it only rejects records that are
malformed, unsafe to publish, or structurally corrupting to the corpus.

## The pipeline

`commit-records.sh` runs these steps per store root, in order, and **aborts
atomically** (no commit, no push) on the first failure, appending an actionable
note — root, failing path(s), which check rejected them — to the librarian
grooming queue (`<state-dir>/grooming-queue.md`, resolved via
`scripts/lib/stores.sh` `procedures_state_dir`).

1. **Pull** — `git pull --rebase` when an upstream is configured (skipped for a
   local-only repo).
2. **Clean-up (normalize)** — for each record path: canonical frontmatter key
   order (the seven keys of `std.record-frontmatter`, then any extra keys in
   original order), `links: {}` when empty, trailing whitespace stripped, and
   the filename kebab-slug made to match the `id` (`<prefix>.<slug>` →
   `<slug>.md`). Idempotent and in place.
3. **Validate — baseline** (all rejections abort+queue):
   - **Frontmatter** — `lint-frontmatter.sh` (schema keys present, `id` unique
     within the root, `links:` resolve, `keywords:` non-empty).
   - **Sanitization** — `check-sanitization.sh` (no personal home paths, Slack
     tokens, or private-key material). `/home/ubuntu/` is an allowed path.
   - **Sections** — `check-sections.sh` (per-kind required sections). WARN-only
     by default; blocks under `LINT_SECTIONS_REQUIRED=1`.
   - **Frontmatter block present** — a record `.md` whose first line is not
     `---` is **blocked**, never warned.
   - **Duplicate id across the whole root** — after the step-1 rebase, the
     entire record tree (not just the changed paths) is scanned; two records
     sharing an `id:` abort. A staged record that is individually clean but
     collides with one already on the rebased history would make
     `build-record-index.sh` abort fleet-wide on the next pull, so it is caught
     here.
   - **Case-twin paths** — two paths differing only by case (over `git ls-files`
     plus staged paths, compared case-insensitively) abort, so a
     case-insensitive macOS checkout cannot wedge a case-sensitive host.
   - **Size cap** — a record file larger than **32768 bytes** is rejected; a
     file of exactly 32768 bytes passes, 32769 bytes is rejected.
4. **Validate — per-store** — if `<root>/scripts/validate.sh` is executable, it
   is run with the changed record paths as `$@`; a non-zero exit aborts. This is
   how a store adds a rule (e.g. the langwatch `<prefix>.langwatch.<slug>`
   namespace) without a plugin release. Contract: exit `0` = admissible,
   non-zero = block; offending paths to stderr.
5. **Index** — `build-record-index.sh --root <root> --out <root>/.index`, so the
   rebuilt index lands in the same commit as the records it describes.
6. **Structured commit** — `git add <paths>` (never `-A`), then a commit whose
   message carries the reason (below). A new commit every drain, never
   `--amend`, never `--force`.
7. **Push** — `git push`; on rejection, `git pull --rebase` and retry once; if
   that still cannot fast-forward, `git rebase --abort`, leave the tree clean,
   and queue the root+files. Never a force-push.

## Commit message template

```
records(<store-basename>): <what>

why: <why>
source: <source>
evidence: <evidence>
```

## Per-kind required sections (check-sections.sh)

| kind | required sections |
|---|---|
| decision | Goal, Chosen path, Outcome |
| solution | The problem shape, The fix |
| failure-mode | Mistake, Correct |
| procedure | Steps |

A kind not listed has no section requirement. Section presence is a heading
whose text contains the named phrase (case-insensitive).
