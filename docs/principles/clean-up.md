---
id: prin.clean-up
kind: principle
date: 2026-06-12
keywords: [cleanup, clean, tree, scratch, tmp, gitignore, dead-reference, stray, runtime]
links: { principles: [prin.file-directory] }
status: active
enforced_by: none-aspirational
title: Clean up after yourself
purpose: Leave the tree cleaner than found; scratch goes to /tmp, durable artifacts get a canonical home, dead references are bugs.
---

# Clean up after yourself

Leave the tree cleaner than you found it.

- Runtime/scratch output (logs, caches, daemon/job state, temp files) goes in `/tmp/` or a gitignored path — **never committed**.
- Durable artifacts get a canonical home + index pointer **the same turn** (see `references/principles/file-directory.md` for kinds → paths); if you retire one, delete it and fix **every** inbound reference (grep first).
- Undocumented load-bearing state, stray top-level files, and dead references are **bugs** — fix them in passing (Boy-Scout, per `references/principles/coding.md`).
- Before deleting or overwriting something you did not create, **look at it**: if it contradicts how it was described, surface that instead of proceeding.

## Why aspirational (no enforcer)

No hook scans for stray top-level files or dead references. The `git-hooks/pre-commit` secrets/paths block is adjacent but does not enforce the cleanup norm itself. This is a NORM until a tree-hygiene lint exists.
