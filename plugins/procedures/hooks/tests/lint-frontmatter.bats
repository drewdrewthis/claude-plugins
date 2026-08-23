#!/usr/bin/env bats
# Tests for scripts/lint-frontmatter.sh — the frontmatter schema linter.
#
# Covers the six checks enforced by the linter:
#   (a) PRESENT   — missing frontmatter fails
#   (b) UNIQUE    — duplicate id across two stores fails
#   (c) RESOLVE   — dangling links: id fails
#   (d) NONEMPTY  — empty keywords: [] fails
#   (e) PRINCIPLES — enforced_by: absence is a WARNING, not a fail
#   (f) PROJECT    — project: is OPTIONAL; present-but-malformed fails
#   (g) DESCRIPTION — description: is OPTIONAL (WARNING if missing);
#     present-but-empty or multi-line fails; LINT_DESCRIPTION_REQUIRED=1
#     promotes a missing description to a fail
#   Store discovery — STORES is derived from the records-root directory tree
#     (scripts/lib/stores.sh), not a hardcoded list — a new store directory
#     is linted with no list to edit; vendored stores stay excluded
#   Targeted mode — linting one file still resolves links against full corpus
#   Targeted mode FAILS CLOSED — a named target that does not exist, or is not
#     a lintable record, is an ERROR; and every run prints `linted N file(s)`
#     so silence can never read as a clean bill of health
#
# Each test builds a tiny fixture corpus under LINT_FRONTMATTER_ROOT so
# results are deterministic and the live corpus is never touched.
# Paths passed to the linter in targeted mode are RELATIVE (to the fixture
# root), matching how pre-commit passes staged-file paths.
#
# Run: bats hooks/tests/lint-frontmatter.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lint-frontmatter.sh"
  FIX="$(mktemp -d)"
  export LINT_FRONTMATTER_ROOT="$FIX"

  # Create all seven store directories.
  mkdir -p "$FIX/references/failure-modes"
  mkdir -p "$FIX/references/decisions"
  mkdir -p "$FIX/references/solutions"
  mkdir -p "$FIX/references/procedures"
  mkdir -p "$FIX/references/research"
  mkdir -p "$FIX/references/principles"
  mkdir -p "$FIX/plans"

  # A canonical VALID record in the failure-modes store.
  cat > "$FIX/references/failure-modes/good.md" <<'EOF'
---
id: fm.good-record
kind: failure-mode
date: 2026-06-12
keywords: [quokka, marsupial]
links: {}
status: active
---
# Good record

A valid record used as the baseline pass case.
EOF

  # A canonical VALID decision record (used as a link target in link-resolve tests).
  cat > "$FIX/references/decisions/anchor.md" <<'EOF'
---
id: dec.anchor
kind: decision
date: 2026-06-12
keywords: [anchorword, baseline]
links: {}
status: active
---
# Anchor decision

A decision record whose id is referenced by the links-resolve tests.
EOF
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# ---- valid record passes ----

@test "valid record: whole-corpus run exits 0" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "valid record: targeted mode on a good file exits 0" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/failure-modes/good.md
  [ "$status" -eq 0 ]
}

# ---- (a) PRESENT: missing frontmatter ----

@test "missing frontmatter block fails" {
  cat > "$FIX/references/failure-modes/no-fm.md" <<'EOF'
# No frontmatter here

Just a heading with no --- fence.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing frontmatter" ]] || [[ "$stderr" =~ "missing frontmatter" ]]
}

# ---- (b) UNIQUE: duplicate id across two stores ----

@test "duplicate id across two stores fails" {
  # Same id 'fm.good-record' already in failure-modes/good.md; put the same
  # id in a decisions record to create a cross-store duplicate.
  cat > "$FIX/references/decisions/dup.md" <<'EOF'
---
id: fm.good-record
kind: decision
date: 2026-06-12
keywords: [dupword]
links: {}
status: active
---
# Duplicate id record
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "duplicate id" ]] || [[ "$stderr" =~ "duplicate id" ]]
}

# ---- (b2) missing required key ----

@test "missing required key 'status' fails" {
  cat > "$FIX/references/decisions/missing-key.md" <<'EOF'
---
id: dec.missing-key
kind: decision
date: 2026-06-12
keywords: [missingkey]
links: {}
---
# Missing status key

This record omits the required 'status:' key.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing required key" ]] || [[ "$stderr" =~ "missing required key" ]]
}

# ---- (d) NONEMPTY: empty keywords ----

@test "empty keywords list fails" {
  cat > "$FIX/references/decisions/empty-kw.md" <<'EOF'
---
id: dec.empty-kw
kind: decision
date: 2026-06-12
keywords: []
links: {}
status: active
---
# Empty keywords

This record has an empty keywords list.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "keywords" ]] || [[ "$stderr" =~ "keywords" ]]
}

# ---- (c) RESOLVE: dangling links id ----

@test "dangling links id fails" {
  cat > "$FIX/references/decisions/dangling.md" <<'EOF'
---
id: dec.dangling
kind: decision
date: 2026-06-12
keywords: [danglingword]
links: { decisions: [dec.does-not-exist] }
status: active
---
# Dangling links

This record references a non-existent id.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "resolves to no record" ]] || [[ "$stderr" =~ "resolves to no record" ]]
}

# ---- valid resolving link ----

@test "valid links reference passes" {
  cat > "$FIX/references/decisions/linking.md" <<'EOF'
---
id: dec.linking
kind: decision
date: 2026-06-12
keywords: [linkingword]
links: { decisions: [dec.anchor] }
status: active
---
# Valid linking record

Links to dec.anchor which exists in the fixture corpus.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---- (e) PRINCIPLES: missing enforced_by is WARNING, not FAIL ----

@test "principle without enforced_by emits warning but does not fail" {
  cat > "$FIX/references/principles/no-enforced-by.md" <<'EOF'
---
id: prin.no-enforced-by
kind: principle
date: 2026-06-12
keywords: [principleword]
links: {}
status: active
---
# Principle without enforced_by

This principle has no enforced_by key — should warn, not fail.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  # Exit must be 0 (warning only, no hard fail).
  [ "$status" -eq 0 ]
  # The warning must appear on stderr (bats captures stderr in $output when
  # the shell pipeline sends it to stderr and run captures both).
  [[ "$output" =~ "WARNING" ]] || [[ "$stderr" =~ "WARNING" ]] || \
    [[ "$output" =~ "aspirational" ]] || [[ "$stderr" =~ "aspirational" ]]
}

# ---- targeted mode resolves links against the whole corpus ----

@test "targeted mode: links are resolved against the full corpus, not just the target" {
  # Add a record that links to dec.anchor (which lives in decisions/anchor.md,
  # NOT in failure-modes/). Pass ONLY this record in targeted mode. The
  # linter must still resolve the link by scanning the whole corpus.
  cat > "$FIX/references/failure-modes/targeted.md" <<'EOF'
---
id: fm.targeted
kind: failure-mode
date: 2026-06-12
keywords: [targetedword]
links: { decisions: [dec.anchor] }
status: active
---
# Targeted record

Links to dec.anchor in a different store — targeted lint must still resolve.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/failure-modes/targeted.md
  [ "$status" -eq 0 ]
}

@test "targeted mode: dangling link in a single file fails" {
  cat > "$FIX/references/failure-modes/targeted-bad.md" <<'EOF'
---
id: fm.targeted-bad
kind: failure-mode
date: 2026-06-12
keywords: [targetbadword]
links: { decisions: [dec.no-such-id] }
status: active
---
# Targeted record with bad link

Links to a non-existent id; targeted lint must catch it.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/failure-modes/targeted-bad.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "resolves to no record" ]] || [[ "$stderr" =~ "resolves to no record" ]]
}

# ---- targeted mode FAILS CLOSED on a target it cannot lint ----
# Every case below used to be a silent `continue`: the run printed nothing at
# all and exited 0, so a typo'd path, a renamed record, or a caller
# word-splitting a filename that contains a space read as "checked, clean".

@test "targeted mode: a named target that does not exist FAILS" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/no-such-record.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not exist" ]] || [[ "$stderr" =~ "does not exist" ]]
}

@test "targeted mode: a path outside the record stores FAILS" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" /nonexistent/nope.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not a lintable record" ]] || [[ "$stderr" =~ "not a lintable record" ]]
}

@test "targeted mode: a REAL record alongside a bogus target still FAILS" {
  # The mixed case is what the pre-commit hook actually produces when an
  # unquoted path word-splits: one resolvable path and one that is not. The
  # good file passing must not launder the bogus one into a green run.
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/failure-modes/good.md /nonexistent/nope.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not a lintable record" ]] || [[ "$stderr" =~ "not a lintable record" ]]
}

@test "targeted mode: INDEX.md is not a lintable record" {
  printf '# Index\n' > "$FIX/references/decisions/INDEX.md"
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" references/decisions/INDEX.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not a lintable record" ]] || [[ "$stderr" =~ "not a lintable record" ]]
}

# ---- the accounting line: silence is never a clean bill of health ----

@test "accounting line prints on a passing targeted run and counts the target" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/failure-modes/good.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontmatter-lint: linted 1 file(s)"* ]]
}

@test "accounting line prints on a FAILING run too" {
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/no-such-record.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"frontmatter-lint: linted 0 file(s)"* ]]
}

@test "accounting line on a whole-corpus run counts every record" {
  # The fixture corpus is exactly the two records built in setup().
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontmatter-lint: linted 2 file(s)"* ]]
}

@test "whole-corpus mode does not fail on non-record paths it never chose" {
  # The fail-closed rule applies to CALLER claims only. A stray file that the
  # corpus walk simply does not pick up must not turn the whole run red.
  printf 'not a record\n' > "$FIX/references/decisions/notes.txt"
  mkdir -p "$FIX/references/decisions/nested"
  printf '# Index\n' > "$FIX/references/decisions/INDEX.md"
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontmatter-lint: linted 2 file(s)"* ]]
}

# ---- editable sub-documents: staged, but never records ----

@test "targeted mode: a procedure's steps/*.md is skipped, not an error" {
  # pre-commit passes STAGED paths as named targets. A step file is a real file
  # someone edits and commits, and corpus_files() deliberately excludes it — so
  # naming it must be a silent skip. Erroring made every steps/*.md edit
  # uncommittable without --no-verify.
  mkdir -p "$FIX/references/procedures/demo/steps"
  printf -- '---\nname: astep\ndescription: a step file\n---\n# Step\n' \
    > "$FIX/references/procedures/demo/steps/astep.md"
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/procedures/demo/steps/astep.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"linted 0 file(s)"* ]]
}

@test "targeted mode: a templates/*.md sub-document is skipped, not an error" {
  mkdir -p "$FIX/references/procedures/demo/templates"
  printf '# Template\n' > "$FIX/references/procedures/demo/templates/t.md"
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/procedures/demo/templates/t.md
  [ "$status" -eq 0 ]
}

@test "targeted mode: skipping sub-documents does not defang the typo guard" {
  # The fail-closed rule exists for typos and renames. Those must still FAIL,
  # or the skip above would launder every bad path into a green run.
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/typo-not-a-file.md
  [ "$status" -ne 0 ]
}

# ---- (f) PROJECT: OPTIONAL key, shape-checked only when present ----
#
# `project:` is the column `query-records.sh --project` filters on. Absent is a
# corpus-wide record and must stay legal (the field was added to a corpus of
# ~1,800 records that carry none). Present-but-malformed must FAIL, because it
# looks scoped and is reachable by no query at all — worse than absent.

_write_project_record() {
  # $1 = filename stem, $2 = the raw `project:` line (or "" to omit the key)
  {
    printf -- '---\n'
    printf 'id: dec.%s\n' "$1"
    printf 'kind: decision\n'
    printf 'date: 2026-08-10\n'
    printf 'keywords: [projectshapekw]\n'
    printf 'links: {}\n'
    printf 'status: active\n'
    [ -n "$2" ] && printf '%s\n' "$2"
    printf -- '---\n'
    printf '# Project shape record\n'
  } > "$FIX/references/decisions/$1.md"
}

@test "project: is OPTIONAL — a record with no project key passes" {
  _write_project_record no-project ""
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/no-project.md
  [ "$status" -eq 0 ]
}

@test "project: owner/repo passes the shape check" {
  _write_project_record ok-owner-repo 'project: langwatch/scenario'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/ok-owner-repo.md
  [ "$status" -eq 0 ]
}

@test "project: a bare repo name passes the shape check" {
  _write_project_record ok-bare 'project: claude-plugins'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/ok-bare.md
  [ "$status" -eq 0 ]
}

@test "project: a quoted scalar passes — the lint normalises as the matcher does" {
  # record-scan.awk strips one outer quote pair before comparing, so a quoted
  # value IS queryable. A lint that rejected it would fail a working record.
  _write_project_record ok-quoted 'project: "langwatch/scenario"'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/ok-quoted.md
  [ "$status" -eq 0 ]
}

@test "project: an uppercase value FAILS — present-but-malformed is not optional" {
  _write_project_record bad-case 'project: LangWatch/Scenario'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/bad-case.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"project: 'LangWatch/Scenario' is malformed"* ]]
}

@test "project: an empty value FAILS — it is neither scoped nor corpus-wide" {
  _write_project_record bad-empty 'project:'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/bad-empty.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"is malformed"* ]]
}

@test "project: a nested owner/group/repo path FAILS — one slash at most" {
  _write_project_record bad-nested 'project: langwatch/group/scenario'
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/bad-nested.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"is malformed"* ]]
}

# ---- (g) DESCRIPTION: OPTIONAL key, WARN-only until the corpus backfills ----
#
# ~940 existing records predate `description:`. A missing description must
# warn, not fail, until LINT_DESCRIPTION_REQUIRED=1 flips the switch after
# backfill. A PRESENT-but-malformed value (empty, or spanning more than one
# line) always hard-fails — a broken field is worse than an absent one.

@test "description: missing warns but does not fail" {
  cat > "$FIX/references/decisions/no-desc.md" <<'EOF'
---
id: dec.no-desc
kind: decision
date: 2026-08-23
keywords: [nodesckw]
links: {}
status: active
---
# No description

This record has no description: key at all.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/no-desc.md
  [ "$status" -eq 0 ]
  [[ "$output" =~ "WARNING" ]] || [[ "$stderr" =~ "WARNING" ]]
  [[ "$output" =~ "description" ]] || [[ "$stderr" =~ "description" ]]
}

@test "description: a valid single-line value passes with no warning" {
  cat > "$FIX/references/decisions/good-desc.md" <<'EOF'
---
id: dec.good-desc
kind: decision
date: 2026-08-23
keywords: [gooddesckw]
links: {}
status: active
description: A short, valid single-line description.
---
# Good description

EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/good-desc.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
}

@test "description: an empty value hard-fails" {
  cat > "$FIX/references/decisions/empty-desc.md" <<'EOF'
---
id: dec.empty-desc
kind: decision
date: 2026-08-23
keywords: [emptydesckw]
links: {}
status: active
description:
---
# Empty description

EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/empty-desc.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "description" ]] || [[ "$stderr" =~ "description" ]]
  [[ "$output" =~ "empty" ]] || [[ "$stderr" =~ "empty" ]]
}

@test "description: a multi-line value hard-fails" {
  cat > "$FIX/references/decisions/multiline-desc.md" <<'EOF'
---
id: dec.multiline-desc
kind: decision
date: 2026-08-23
keywords: [multilinedesckw]
links: {}
status: active
description: |
  This spans
  two lines.
---
# Multi-line description

EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT" \
      references/decisions/multiline-desc.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "description" ]] || [[ "$stderr" =~ "description" ]]
  [[ "$output" == *"multiple lines"* ]] || [[ "$stderr" == *"multiple lines"* ]]
}

@test "LINT_DESCRIPTION_REQUIRED=1 promotes a missing description to a hard failure" {
  cat > "$FIX/references/decisions/no-desc-required.md" <<'EOF'
---
id: dec.no-desc-required
kind: decision
date: 2026-08-23
keywords: [nodescreqkw]
links: {}
status: active
---
# No description, but required this time

EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" LINT_DESCRIPTION_REQUIRED=1 bash "$SCRIPT" \
      references/decisions/no-desc-required.md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "description" ]] || [[ "$stderr" =~ "description" ]]
  [[ "$output" != *"WARNING"* ]]
}

@test "missing-description summary count reflects how many linted files lack one" {
  # The two setup() baseline records (good.md, anchor.md) have no description
  # either, so a whole-corpus run counts all three.
  cat > "$FIX/references/decisions/no-desc-2.md" <<'EOF'
---
id: dec.no-desc-2
kind: decision
date: 2026-08-23
keywords: [nodesc2kw]
links: {}
status: active
---
# Another record without description

EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontmatter-lint: 3 file(s) missing description"* ]]
}

# ---- store discovery: STORES is derived from the directory tree ----
#
# scripts/lib/stores.sh discovers stores by listing directories under
# RECORDS_ROOT instead of a hardcoded array, so a brand-new store directory
# is linted with no list to edit — and a vendored store stays excluded even
# though it is now structurally indistinguishable from a real one.

@test "a newly-created directory in the records root is picked up as a store without editing any list" {
  mkdir -p "$FIX/references/newstore"
  cat > "$FIX/references/newstore/bad.md" <<'EOF'
---
id: new.bad-record
kind: newkind
date: 2026-08-23
keywords: [newstorekw]
links: {}
---
# Bad record in a brand-new store directory

Missing the required 'status:' key — proves the new directory is being
linted without any STORES list edit.
EOF
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"references/newstore/bad.md"* ]] || [[ "$stderr" == *"references/newstore/bad.md"* ]]
  [[ "$output" == *"missing required key 'status:'"* ]] || [[ "$stderr" == *"missing required key 'status:'"* ]]
}

@test "vendored stores are still excluded from lint even as a records-root subdirectory" {
  # "titw" is VENDOR_STORES in scripts/lib/stores.sh: queried by
  # query-records.sh but never linted (titw check validates it at publish
  # time). Give it a deliberately-broken record — no frontmatter at all — and
  # confirm the whole-corpus run neither counts nor fails on it.
  mkdir -p "$FIX/references/titw"
  printf '# not a record, no frontmatter at all\n' > "$FIX/references/titw/vendored.md"
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontmatter-lint: linted 2 file(s)"* ]]
}
