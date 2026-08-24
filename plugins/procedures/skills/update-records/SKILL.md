---
name: update-records
description: "Write any durable knowledge artifact to its store — mistake, decision, solution, failure-mode, procedure, evolution, principle, invariant, policy, standard, reference, or skill. THE single entry point: there is no separate create or log command. Use when the user corrects you (mistake), a judgment call is resolved (decision), a non-obvious fix is confirmed (solution), a recurring agent mistake reaches the promotion bar (failure-mode), or novel work needs crystallizing and /how-do-i returned nothing (procedure, reference, skill, or a rule kind). Triggers: 'log a mistake', 'record this decision', 'document this fix', 'promote this to a failure mode', 'write a procedure for this', 'create a new skill', or codifying a rule after a correction."
user-invocable: true
argument-hint: "<kind> [text]"
---

# /update-records

THE single entry point for every knowledge artifact. Pick `<kind>` from the table, then follow that row. There is no separate create command — creating and recording are the same act, and splitting them across two skills only made agents pick the wrong one.

| `<kind>` | how it is written | lands in |
|---|---|---|
| `mistake` | `log-record.sh` | `~/.claude/mistakes.jsonl` |
| `decision` | `log-record.sh` | `references/decisions/` |
| `solution` | `log-record.sh` | `references/solutions/` |
| `failure-mode` | `log-record.sh` | `references/failure-modes/` |
| `procedure` | follow `references/create-procedure.procedure.md` | `references/procedures/<name>/PROCEDURE.md` + seed its `EVOLUTION.md` |
| `evolution` | by hand from `templates/evolution.template.md` | beside the procedure it tracks |
| `principle` `invariant` `policy` `standard` | by hand from the matching `templates/<kind>.template.md` | `references/{principles,invariants,policies,standards}/` |
| `reference` | follow `references/create-reference.procedure.md` | the store that procedure names |
| `skill` | follow `references/create-skill.procedure.md` | a new skill directory — only when the operation earns an invocation handle |

The four script-backed kinds call the deterministic writer:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/log-record.sh" <kind> [flags…]
```

The script owns the mechanical half — building the JSON via `jq -n` (never an inline echoed brace-literal) and writing the file. No index files are maintained: discovery is the record's frontmatter (id, description, keywords) plus `/how-do-i`, which scans every store via `build-record-index.sh` and its numbered index. You own the JUDGMENT half below. Templates live in `${CLAUDE_PLUGIN_ROOT}/skills/update-records/templates/`, the longhand procedures in `${CLAUDE_PLUGIN_ROOT}/skills/update-records/references/`.

**Choosing among the four rule kinds:** an **invariant** forbids absolutely and has no carve-outs — the moment you write "except when", it is a **principle**, which guides judgment where the rules do not reach. A **policy** grants or withholds authority and is in force from merge until a line is struck. A **standard** states the measurable bar a finished artifact must clear, never the steps to clear it. These are not a severity scale: promoting a rule you still intend to break trains every reader to treat the whole kind as advice.

**Rules that hold for every kind:** check `/how-do-i` for an existing artifact first; six-key frontmatter on every record (the frontmatter hook enforces it); draft-then-promote — a first success earns a draft, promotion needs the gate in `docs/adrs/001-procedural-knowledge-system.md` ("Evolution"). Patching an existing PROCEDURE is `/evolve-procedure`, not this skill.

`--project <owner/repo>` is OPTIONAL on `decision`, `solution`, and `failure-mode`, and writes the frontmatter `project:` key so repo-scoped records are distinguishable from corpus-wide ones at a glance. Pass it only when the record is genuinely about ONE repo; omit it for anything corpus-wide.

Resume the interrupted conversation immediately after — the four script-backed kinds take <10 seconds and must not derail it.

---

## kind = mistake

Appends a structured entry to `~/.claude/mistakes.jsonl`. Consumed by the procedure-scout, which sweeps failure-modes + `mistakes.jsonl` per query.

**Triggers:** user correction ("no", "wrong", "not that", a redirect); self-catch; after codifying a rule from a correction; manual `/update-records mistake <description>`.

**Gather the fields:**

| Field | How to determine |
|-------|-----------------|
| **category** | One of: `wrong-action`, `wrong-assumption`, `forgot-instruction`, `wasted-work`, `wrong-tool`, `wrong-model`, `style-violation`, `other` |
| **description** | What went wrong — one specific sentence |
| **correction** | What should have happened — one sentence |
| **skill** | Active skill, if any (e.g. `manage-sessions`); omit if none |
| **severity** | `low` (style/minor), `medium` (wasted work, wrong approach), `high` (destructive, violated explicit instruction) |
| **trigger** | `human` (user corrected) or `self` (caught own mistake) |
| **scenario-matched** | Slug of a matching `references/scenarios/<slug>.md`, or `null` |

**Then find the join keys (do this BEFORE calling the script):**

1. **`recurrence_of`** — grep for a near-match prior entry (same `pattern`/`category` or overlapping `description` keywords). ⚠ `fm.unverified-claim-acted-on`: this is set correctly ONLY if you find the prior entry first.

   ```bash
   grep -iE '<2-3 keywords from this mistake>' ~/.claude/mistakes.jsonl | jq -sr '[.[] | select(.ts)] | sort_by(.ts) | .[0].ts // empty'
   ```

   If a prior entry shares the same root pattern, pass `--recurrence-of "<that-ts>"` — the `ts` of the **`pattern`'s** earliest occurrence, never the narrower `face`'s. The first occurrence of a pattern has no `recurrence_of` — omit the flag. A prior entry sharing your `face` (step 2) does not change which `ts` this flag points to: `face` is an orthogonal annotation naming a variant of a registry record, not a second recurrence lineage.

2. **`pattern`** — match against the `failure-modes/` registry for the join key:

   ```bash
   grep -rln '^keywords:' ~/.claude/references/failure-modes/ | head    # browse the registry
   grep -rin '<2-3 keywords from this mistake>' ~/.claude/references/failure-modes/
   ```

   Each record's frontmatter `id` is `fm.<row-id>`. If matched, pass `--pattern "<row-id>"` (WITHOUT the `fm.` prefix). Omit if no record matches.

   If the mistake is a narrower FACE of a broader record in the registry, pass the broader record's `--pattern` and name the specific face with `--face "<face-name>"`.

**Call the script** (it stamps `ts`, `project`, `session` if you omit them):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/log-record.sh" mistake \
  --category "<category>" --description "<description>" --correction "<correction>" \
  --severity "<severity>" --trigger "<trigger>" --skill "<skill-or-empty>" \
  --scenario-matched "<slug-or-null>" \
  [--pattern "<row-id>"] [--face "<face>"] [--recurrence-of "<earliest-ts>"]
```

**After:** scan the last ~20 entries for the same `category` + similar `description` (or a shared `recurrence_of` chain). If **3+** entries share a pattern with no matching record in `references/failure-modes/`, promote it with `/update-records failure-mode <slug> "<rule>"` (see below). Below the ≥3 bar, leave the EVENT logged. Promotion at scale (condensation, demotion) stays a deliberate maintenance pass.

**Boundaries:** don't log clarifications (a correction changes direction; a clarification adds detail). Don't write vague entries ("made a mistake") — be specific.

---

## kind = decision

Writes `references/decisions/<date>-<slug>.md` (id `dec.<date>-<slug>`). No index file is maintained — discovery is the frontmatter (id, description, keywords) plus `/how-do-i`'s store-wide index. Consumed by the pre-action grep that prevents relitigating settled choices.

**Pre-action grep first** — `grep -rl '<keywords>' ~/.claude/references/decisions/`; if the question is already settled, link the existing record instead of creating a duplicate.

**Gather:** `slug` (kebab-case, ≤7 words, names the *question* resolved), `keywords` (lowercase: domain, options considered, key actors), a one-line `summary`, and the prose `body` — sections Goal / Chosen path / Consequences / Outcome. Leave `[pending]` for sections that need future evidence — that is correct on creation.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/log-record.sh" decision \
  --slug "<slug>" --title "<title>" --summary "<one-line summary>" \
  --keywords '[<lowercase, comma-separated>]' \
  [--body "$(cat <<'EOF'
## Goal
…
EOF
)"]
```

If no `--body` is passed, the script writes its default skeleton with `[pending]` sections. `status: active` at creation; flip to `resolved` only when the outcome is known (a future edit). Record only decisions already made, not ones being weighed.

Re-running with the same `--slug`/`--date` REFUSES if the file already exists (no merge) — hand-edit the file directly to flip `status` or fill in `[pending]` sections, or pass `--force` to overwrite it entirely.

---

## kind = solution

Writes `references/solutions/<date>-<slug>.md` (id `sol.<date>-<slug>`, plus `situation_tags` and `resolve_after`). No index file is maintained — discovery is the frontmatter (id, description, keywords) plus `/how-do-i`'s store-wide index. Consumed by the procedure-scout's pre-action sweep.

**Gather:** `slug` (kebab-case, ≤6 words, names the *problem* not the fix), `keywords` (problem domain, tool name, error class), `situation-tags` (lowercase situation class: `daemon`, `gh-cli`, `env-config`, …), `resolve-after` (~3 months out; env/version hacks expire faster), a one-line `summary` = the canonical resolution, and the prose `body` (Symptom / Rule / optional Check / optional Recipe — Recipe only when flags/order matter).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/log-record.sh" solution \
  --slug "<slug>" --title "<title>" --summary "<rule in one imperative sentence>" \
  --keywords '[<lowercase>]' --situation-tags '[<lowercase>]' --resolve-after "<YYYY-MM-DD>" \
  [--body "$(cat <<'EOF'
## Symptom
…
EOF
)"]
```

Record a RESOLVED situation only. `status: resolved` always; gate revisiting with `resolve_after`, not a different status. Don't conflate with failure-mode: a solution is a situational fix (env/tool/config); a failure-mode is a recurring *agent behavior* mistake.

Re-running with the same `--slug`/`--date` REFUSES if the file already exists (no merge) — hand-edit the file directly to revise it, or pass `--force` to overwrite it entirely.

---

## kind = failure-mode

Writes `references/failure-modes/<slug>.md` (BARE slug filename, no `fm.` prefix; id `fm.<slug>`; `rule:` field = the one-sentence rule, whole and self-contained). Does NOT merge on re-run — see below. Consumed by the procedure-scout, which sweeps failure-modes + `mistakes.jsonl` per query.

**Triggers:** a mistake pattern reached **≥3** occurrences in `~/.claude/mistakes.jsonl` (the promotion bar, script-enforced); "promote this to a rule"; a FACE record nesting under a mega parent.

**Check the gate + prior entry FIRST:**

```bash
grep -rl '<2-3 keywords>' ~/.claude/references/failure-modes/    # already exists?
grep -c '"pattern":"<slug>"' ~/.claude/mistakes.jsonl            # occurrence count
```

- The script ENFORCES the ≥3 gate on a NEW record (counts `"pattern":"<slug>"` in the jsonl and refuses below 3). Below the bar, log the EVENT with `/update-records mistake` instead.
- **If a record already exists, the script REFUSES by default** (non-zero exit, file untouched) — it does not read or merge the existing content. To add a face/instance or revise prose on a record that already exists, **hand-edit the file directly**; that is how every real failure-mode record has actually grown. `--force` overwrites the ENTIRE file from scratch (every prior face gone) and exists only for a genuinely intentional full rewrite — never pass it to "update" a record whose content you want to keep.

**Gather:** `slug` (kebab-case, ≤6 words, names the failure behavior — the SAME bare slug used as the jsonl `pattern`, so the join holds), `rule` (ONE crisp imperative sentence — write it so a fresh agent can act on it in isolation), `keywords`, and the prose `mistake` / `correct` sections.

**Standalone vs FACE:** a standalone record stands on its own. A FACE of a mega parent passes `--face-of <parent-slug-without-fm-prefix>` (and the parent gets `--mega true`); a FACE is read through its parent, not as a peer.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/log-record.sh" failure-mode \
  --slug "<slug>" --rule "<one crisp imperative sentence>" \
  --keywords '[<lowercase>]' \
  [--mistake "<≤3-sentence description>"] [--correct "<full correct behavior>"] \
  [--face-of "<parent-slug>"] [--mega true]
```

New records start `verification: pending`, `status: active` — do not invent evidence.

**failure-mode vs mistake:** `/update-records mistake` appends ONE structured EVENT per occurrence (cheap, at correction time). `/update-records failure-mode` creates/updates the durable RECORD that `pattern` points AT — and requires ≥3 occurrences. They compose: log the EVENT each time; promote to a RECORD when it recurs.
