---
id: proc.writing-records
kind: procedure
date: 2026-08-23
keywords: [writing-records, description, retrieval, frontmatter, update-records, procedure-authoring]
links: { standards: [std.record-frontmatter], procedures: [] }
status: active
description: How to author any knowledge record's frontmatter and body, and the sub-case of writing a procedure's steps.
---

# Writing Records

How to author a knowledge record of any kind, and the sub-case of authoring a
procedure. Schema authority is `RECORD_FRONTMATTER.md` (`std.record-frontmatter`) —
this file does not restate it, only operationalizes the authoring steps.

**Not when:** you are unsure which kind to use. Kind is derived from the store
directory (`references/<store>/` → singular of `<store>`), not chosen freely —
pick the directory first, by matching your content's shape against the kind
definitions in `skills/update-records/templates/*.md` (each template's HOW-TO
comment states what does and does not belong in that kind).

## Steps — any kind

1. **Pick the store directory.** That directory's singular name is `kind` —
   do not author `kind` by hand.
2. **Copy the matching template** from `plugins/procedures/skills/update-records/templates/<kind>.template.md`.
3. **Write `description` first**, before any other field. See "Writing a
   description" below — writing it first forces you to know what the record
   *says* before you write the body that says it.
4. **Fill `id`, `date`, `keywords`, `links`, `status`** per `std.record-frontmatter`'s
   per-kind prefix/status table. `keywords` is named entities only (tools,
   repos, commands) — not a paraphrase of `description`.
5. **Write the body** using the copied template's sections. Do not add
   sections the template doesn't have; do not restate the frontmatter
   `description` as a body sentence.
6. **Delete the template's HOW-TO-USE comment block** before saving — it is
   authoring guidance, not record content.

## Writing a `description`

The retrieval match surface: one line, ~120 chars, neutral third-person,
states what the record *says* — its claim or mechanism — not what it is
*about* and not its kind or filename.

Rules:
- Contains the specific mechanism, condition, or number a question would
  match against. A description with no specific in it matches every record
  and none.
- Never restates the topic word or the kind noun ("decision", "fix", "bug") —
  those are already in `kind` and the filename; repeating them burns the one
  line without adding match surface.
- Third person, present tense, no hedging.

Worked example — `sol.2026-07-13-langwatch-ci-green-forgeable-verify-shard-tally`:

| | Description | Why |
|---|---|---|
| Bad | `CI green check fix for LangWatch.` | Restates the kind (a "fix"), restates the topic word ("CI green check") already in the filename. Zero mechanism — a question like "why does a green shard hide failing tests" cannot match it. |
| Good | `A vitest shard whose harness force-exits 0 reports success while containing failing tests and no summary tally line; verify the tally, not the conclusion.` | Names the mechanism (force-exit 0 masking failures), the observable symptom (no tally line), and the fix (verify the tally). A question about masked CI failures, force-exit, or vitest shards all match. |

The delta: the bad version could describe hundreds of unrelated records ("a
fix", "a check"). The good version could only describe this one, because it
states the specific mechanism, not the category.

## Steps — writing a procedure specifically

1. **Steps are imperative, numbered, each independently runnable** — a reader
   starting cold at step 4 must be able to run it without having read 1–3
   for context (only for state, not for meaning).
2. **Verbatim commands, not paraphrased ones.** Where a command exists, paste
   it copy-pasteable; do not describe what the command roughly does instead.
3. **Fuse each warning to its step** with `⚠ <clause>` inline, at the exact
   step the trap bites — not in a trailing "gotchas" section read after the
   mistake.
4. **State decisions as branches**, not prose: `<condition> → <action>.
   <other condition> → <action>.`
5. **No motivation, no "why we do this" section.** If a past failure produced
   this step, that backstory goes in the sibling `EVOLUTION.md`
   (`proc.<category>.<name>.evolution`), not in the procedure body — see
   `evolution.template.md`.
6. **Add a `Boundaries` section** naming what looks like this procedure's job
   but isn't, and who owns it instead.

PROCEDURE.md vs EVOLUTION.md: PROCEDURE.md is present-tense only — current
steps, current warnings, current boundaries. EVOLUTION.md holds every past
version's rationale, dated entries, newest first, each with its evidence (a
number, a log line, a quote) — "fixed a typo" is not an entry; git log
already has that.

## Self-check before declaring done

- [ ] `kind` matches the store directory the file lives in; not hand-picked.
- [ ] `description` was written before `id`/`keywords`/body, is ~120 chars,
      third-person, and names a mechanism/specific — not the kind, not the
      filename topic.
- [ ] `id` uses the correct kind prefix; `status` is a valid value for that
      kind (`std.record-frontmatter` table).
- [ ] `keywords` non-empty, named entities only.
- [ ] `links` targets resolve to real record ids, or `{}`.
- [ ] Body uses only the copied template's sections; HOW-TO-USE comment block
      deleted.
- [ ] If a procedure: every step independently runnable, commands verbatim,
      warnings fused inline, no motivation prose, `Boundaries` section present.
- [ ] If any past rationale was cut, it landed in the sibling `EVOLUTION.md`,
      not deleted outright.
