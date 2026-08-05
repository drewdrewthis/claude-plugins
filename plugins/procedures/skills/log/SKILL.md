---
name: log
description: "Log a durable record — a mistake, decision, solution, or failure-mode — to its record store. One entry point for all four record kinds. Use when the user corrects you (mistake), a judgment call is resolved (decision), a non-obvious fix is confirmed (solution), or a recurring agent mistake reaches the promotion bar (failure-mode). Triggers: 'log a mistake', 'record this decision', 'document this fix', 'promote this to a failure mode', or /evolve codifying a rule."
user-invocable: true
argument-hint: "<kind> [text]"
---

# /log

One entry point for the four record kinds. `<kind>` is `mistake`, `decision`, `solution`, or `failure-mode`. This skill gathers the JUDGMENT fields, then calls the deterministic writer:

```
scripts/log-record.sh <kind> [flags…]
```

The script owns the mechanical half — building the JSON via `jq -n` (never an inline echoed brace-literal — the apostrophe-in-jq bug the old `log-mistake` had), writing the file, and regenerating the relevant INDEX/view (`gen-decisions-index.sh`, `gen-solutions-index.sh`, or `common-mistakes.md`). You own the JUDGMENT half below.

Resume the interrupted conversation immediately after — every kind takes <10 seconds and must not derail it.

---

## kind = mistake

Appends a structured entry to `~/.claude/mistakes.jsonl`. Consumed by `deep-reflect`, `/evolve`, and `retro`.

**Triggers:** user correction ("no", "wrong", "not that", a redirect); self-catch; from `/evolve` after codifying a rule; manual `/log mistake <description>`.

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
   grep -iE '<2-3 keywords from this mistake>' ~/.claude/mistakes.jsonl | tail -3
   ```

   If a prior entry shares the same root pattern, pass `--recurrence-of "<that-ts>"` (the earliest occurrence's `ts`). The first occurrence of a pattern has no `recurrence_of` — omit the flag.

2. **`pattern`** — match against the `failure-modes/` registry for the join key:

   ```bash
   grep -rln '^keywords:' ~/.claude/references/failure-modes/ | head    # browse the registry
   grep -rin '<2-3 keywords from this mistake>' ~/.claude/references/failure-modes/
   ```

   Each record's frontmatter `id` is `fm.<row-id>`. If matched, pass `--pattern "<row-id>"` (WITHOUT the `fm.` prefix). Omit if no record matches.

   **Merged ids (2026-06-10 condensation):** if the mistake matches any retired id — `claim-done-without-evidence`, `speculation-with-false-precision`, `dependency-conclusion-from-partial-read`, `recipe-untested-because-test-bypasses-recipe`, `cross-layer-wire-untested`, `stale-prove-it-marker-after-push`, `self-defeating-evidence-cmd`, `assumed-block` — pass `--pattern "unverified-claim-acted-on"` and record the specific face with `--face "<face-name>"`. Do NOT rewrite historical entries.

**Call the script** (it stamps `ts`, `project`, `session` if you omit them; it regenerates `common-mistakes.md` automatically):

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/log-record.sh" mistake \
  --category "<category>" --description "<description>" --correction "<correction>" \
  --severity "<severity>" --trigger "<trigger>" --skill "<skill-or-empty>" \
  --scenario-matched "<slug-or-null>" \
  [--pattern "<row-id>"] [--face "<face>"] [--recurrence-of "<earliest-ts>"]
```

**After:** scan the last ~20 entries for the same `category` + similar `description` (or a shared `recurrence_of` chain). If **3+** entries share a pattern with no matching record in `references/failure-modes/`, promote it with `/log failure-mode <slug> "<rule>"` (see below). Below the ≥3 bar, leave the EVENT logged. Promotion at scale (condensation, demotion) stays `/evolve`'s job.

**Boundaries:** don't log clarifications (a correction changes direction; a clarification adds detail). Don't write vague entries ("made a mistake") — be specific.

---

## kind = decision

Writes `references/decisions/<date>-<slug>.md` (id `dec.<date>-<slug>`) and regenerates `references/decisions/INDEX.md` via `scripts/gen-decisions-index.sh` (the INDEX is a generated view — never hand-append a row). Consumed by the pre-action grep that prevents relitigating settled choices. Mirrors `/decide` Phase 6 — if `/decide` already wrote the artifact, do NOT duplicate it; just note the existing path.

**Pre-action grep first** — `grep -rl '<keywords>' ~/.claude/references/decisions/`; if the question is already settled, link the existing record instead of creating a duplicate.

**Gather:** `slug` (kebab-case, ≤7 words, names the *question* resolved), `keywords` (lowercase: domain, options considered, key actors), a one-line `summary`, and the prose `body` (the `/decide` Phase-6 template: Goal / Values protocol / Chosen path / Autonomy verdict / Consequences foreseen / materialized [pending] / Outcome [pending] / …). Leave `[pending]` for sections that need future evidence — that is correct on creation.

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/log-record.sh" decision \
  --slug "<slug>" --title "<title>" --summary "<one-line summary>" \
  --keywords '[<lowercase, comma-separated>]' \
  [--body "$(cat <<'EOF'
## Goal
…
EOF
)"]
```

If no `--body` is passed, the script writes the standard `/decide` Phase-6 skeleton with `[pending]` sections. `status: active` at creation; flip to `resolved` only when the outcome is known (a future edit). Record only decisions already made, not ones being weighed.

Re-running with the same `--slug`/`--date` REFUSES if the file already exists (no merge) — hand-edit the file directly to flip `status` or fill in `[pending]` sections, or pass `--force` to overwrite it entirely.

---

## kind = solution

Writes `references/solutions/<date>-<slug>.md` (id `sol.<date>-<slug>`, plus `situation_tags` and `resolve_after`) and regenerates `references/solutions/INDEX.md` via `scripts/gen-solutions-index.sh` (the INDEX is a generated view — never hand-append a row). Consumed by the pre-action grep in `common-mistakes.md`.

**Gather:** `slug` (kebab-case, ≤6 words, names the *problem* not the fix), `keywords` (problem domain, tool name, error class), `situation-tags` (lowercase situation class: `daemon`, `gh-cli`, `env-config`, …), `resolve-after` (~3 months out; env/version hacks expire faster), a one-line `summary` = the canonical resolution, and the prose `body` (Symptom / Rule / optional Check / optional Recipe — Recipe only when flags/order matter).

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/log-record.sh" solution \
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

Writes `references/failure-modes/<slug>.md` (BARE slug filename, no `fm.` prefix; id `fm.<slug>`; `rule:` field = the exact `common-mistakes.md` cell) and regenerates `common-mistakes.md`. Does NOT merge on re-run — see below. Consumed every session via the always-loaded `common-mistakes.md`.

**Triggers:** a mistake pattern reached **≥3** occurrences in `~/.claude/mistakes.jsonl` (the `/evolve` Phase 2.5 promotion bar); "promote this to a rule"; a FACE record nesting under a mega parent.

**Check the gate + prior entry FIRST:**

```bash
grep -rl '<2-3 keywords>' ~/.claude/references/failure-modes/    # already exists?
grep -c '"pattern":"<slug>"' ~/.claude/mistakes.jsonl            # occurrence count
```

- The script ENFORCES the ≥3 gate on a NEW record (counts `"pattern":"<slug>"` in the jsonl and refuses below 3). Below the bar, log the EVENT with `/log mistake` instead.
- **If a record already exists, the script REFUSES by default** (non-zero exit, file untouched) — it does not read or merge the existing content. To add a face/instance or revise prose on a record that already exists, **hand-edit the file directly**; that is how every real failure-mode record has actually grown. `--force` overwrites the ENTIRE file from scratch (every prior face gone) and exists only for a genuinely intentional full rewrite — never pass it to "update" a record whose content you want to keep.

**Gather:** `slug` (kebab-case, ≤6 words, names the failure behavior — the SAME bare slug used as the jsonl `pattern`, so the join holds), `rule` (ONE crisp imperative sentence — the entire table cell; write it so a fresh agent can act on it in isolation), `keywords`, and the prose `mistake` / `correct` sections.

**Standalone vs FACE:** a standalone record gets its own `common-mistakes.md` row. A FACE of a mega parent passes `--face-of <parent-slug-without-fm-prefix>` (and the parent gets `--mega true`); FACE records are NOT emitted as their own row.

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/log-record.sh" failure-mode \
  --slug "<slug>" --rule "<one crisp imperative sentence>" \
  --keywords '[<lowercase>]' \
  [--mistake "<≤3-sentence description>"] [--correct "<full correct behavior>"] \
  [--face-of "<parent-slug>"] [--mega true]
```

The script regenerates `common-mistakes.md` after the write (joining the registry against the real jsonl `pattern` counts, stripping `fm.` to match). NEVER hand-edit `common-mistakes.md` — a pre-commit guard rejects a divergent copy. New records start `verification: pending`, `status: active` — do not invent evidence.

**failure-mode vs mistake:** `/log mistake` appends ONE structured EVENT per occurrence (cheap, at correction time). `/log failure-mode` creates/updates the durable RECORD that `pattern` points AT — and requires ≥3 occurrences. They compose: log the EVENT each time; promote to a RECORD when it recurs.
