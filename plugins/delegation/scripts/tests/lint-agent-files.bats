#!/usr/bin/env bats
# Tests for scripts/lint-agent-files.sh — the agent-file structural linter.
#
# Covers every rule the linter enforces:
#   R1 FRONTMATTER — missing block, a block missing `name:`, missing `description:`
#   R2 ROLE        — no `Role` heading
#   R3 BOUNDARIES  — no `Boundaries` heading
#   R4 NO-DATE     — an ISO date anywhere in the file
#   R5 NO-ISSUEREF — an issue/PR reference anywhere in the file, and the
#                    markdown-anchor shapes that must NOT be mistaken for one
#   W1 SIZE        — over budget WARNS (reviewer/agent budgets differ), AT the
#                    boundary does not, and the class survives malformed `name:`
#   W2 MODEL       — missing `model:` WARNS
#   L1 STALE       — a .lint-legacy entry pointing at nothing
#   L2 RATCHET     — a .lint-legacy entry that now conforms (shrink-only)
#   grandfathering — a listed violator WARNS instead of failing
#   CODEX_SNAPSHOT=1 — every hard failure downgrades to a WARN, exit 0
#
# …and the FAIL-OPEN surfaces the rule tests never touched:
#   targeted mode  — a named target that does not exist / is not an agent file
#                    is an ERROR, not a silent skip
#   accounting     — every run states how many files it linted, so silence can
#                    never be read as "checked, clean"
#   messages       — R4/R5 quote the token that fired (a column-1 excerpt cut
#                    it away), and the failure epilogue only recites the R-rule
#                    contract when an R-rule actually fired
#
# Each test builds a tiny fixture agent tree under LINT_AGENT_FILES_ROOT so
# results are deterministic and the live agents/ tree is never touched.
# Paths passed to the linter in targeted mode are RELATIVE (to the fixture
# root), matching how pre-commit passes staged-file paths.
#
# CODEX_SNAPSHOT is pinned explicitly on every invocation: inheriting it from
# the ambient environment would silently turn every hard-fail assertion into a
# test of nothing.
#
# Run: bats scripts/tests/lint-agent-files.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../lint-agent-files.sh"
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/agents"
  write_agent "$FIX/agents/good.md" good-agent
}

teardown() {
  [ -n "${FIX:-}" ] && chmod -R u+rwX "$FIX" 2>/dev/null
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# Write a fully conforming agent file. $1 = path, $2 = frontmatter name.
write_agent() {
  cat > "$1" <<EOF
---
name: $2
description: "Baseline conforming agent file used as the pass case."
model: sonnet
---

# Role

Does exactly the one thing the roster says it does.

# Boundaries

Never does the thing another agent owns.
EOF
}

# Append $1 filler lines that trip no rule (no dates, no issue refs).
pad() {
  local f="$1" n="$2" i
  for ((i = 0; i < n; i++)); do
    echo "Filler line that trips no rule." >> "$f"
  done
}

# Grow $1 to EXACTLY $2 total lines (derived, not hardcoded, so the boundary
# tests below stay honest if write_agent's preamble ever changes length).
grow_to() {
  local f="$1" target="$2" have
  have="$(awk 'END{print NR}' "$f")"
  pad "$f" "$((target - have))"
}

# Run the linter against the fixture tree with the authoring profile.
lint() {
  run env LINT_AGENT_FILES_ROOT="$FIX" CODEX_SNAPSHOT=0 bash "$SCRIPT" "$@"
}

# How many times $1 occurs across the whole captured output.
occurrences() {
  printf '%s' "$output" | grep -o -- "$1" | wc -l | tr -d ' '
}

# ---- baseline: a clean file passes with only the accounting line ----

@test "clean agent file: whole-tree run exits 0 with no findings" {
  lint
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}

@test "clean agent file: targeted mode exits 0" {
  lint agents/good.md
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}

# ---- accounting line: what actually got linted is always stated ----

@test "accounting: the linted-file count reflects the whole tree" {
  write_agent "$FIX/agents/second.md" second
  write_agent "$FIX/agents/third.md" third
  lint
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 3 file(s)" ]
}

@test "accounting: targeted mode counts only the named files" {
  write_agent "$FIX/agents/second.md" second
  write_agent "$FIX/agents/third.md" third
  lint agents/second.md agents/third.md
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 2 file(s)" ]
}

# ---- targeted mode FAILS CLOSED on a path it cannot lint ----

@test "targeted mode: a named target that does not exist is an ERROR, not a silent skip" {
  lint agents/nope.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/nope.md: named target does not exist"* ]]
  [[ "$output" == *"agent-lint: linted 0 file(s)"* ]]
}

@test "targeted mode: a named non-agent path is an ERROR" {
  mkdir -p "$FIX/agents/sub"
  echo "notes" > "$FIX/agents/sub/notes.md"
  lint agents/sub/notes.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/sub/notes.md: not a lintable agent file"* ]]
  [[ "$output" == *"agent-lint: linted 0 file(s)"* ]]
}

@test "targeted mode: naming EVOLUTION.md explicitly is an ERROR" {
  echo "# log" > "$FIX/agents/EVOLUTION.md"
  lint agents/EVOLUTION.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/EVOLUTION.md: not a lintable agent file"* ]]
}

@test "targeted mode: one bad path does not stop the good ones from being linted" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"
  lint agents/nope.md agents/no-role.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/nope.md: named target does not exist"* ]]
  [[ "$output" == *"agents/no-role.md: R2:"* ]]
  [[ "$output" == *"agent-lint: linted 1 file(s)"* ]]
}

# ---- R1 FRONTMATTER ----

@test "R1: missing frontmatter block fails" {
  cat > "$FIX/agents/no-fm.md" <<'EOF'
# Role

No frontmatter fence above this line.

# Boundaries

Nothing.
EOF
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-fm.md: R1:"* ]]
  [[ "$output" == *"missing frontmatter block"* ]]
}

@test "R1: frontmatter without name: fails" {
  cat > "$FIX/agents/no-name.md" <<'EOF'
---
description: "Has a description but no name."
model: sonnet
---

# Role

Nameless.

# Boundaries

Nothing.
EOF
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-name.md: R1:"* ]]
  [[ "$output" == *'"name:"'* ]]
}

@test "R1: frontmatter without description: fails" {
  cat > "$FIX/agents/no-desc.md" <<'EOF'
---
name: no-desc
model: sonnet
---

# Role

Has a name but no description.

# Boundaries

Nothing.
EOF
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-desc.md: R1:"* ]]
  [[ "$output" == *'"description:"'* ]]
}

# ---- R2 ROLE ----

@test "R2: missing Role heading fails, and fires alone" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-role.md: R2:"* ]]
  [[ "$output" != *"agents/no-role.md: R3:"* ]]
  [[ "$output" != *"agents/no-role.md: R1:"* ]]
}

# ---- R3 BOUNDARIES ----

@test "R3: missing Boundaries heading fails, and fires alone" {
  write_agent "$FIX/agents/no-bounds.md" no-bounds
  sed -i 's/^# Boundaries$/# Limits/' "$FIX/agents/no-bounds.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-bounds.md: R3:"* ]]
  [[ "$output" != *"agents/no-bounds.md: R2:"* ]]
}

# ---- R4 NO-DATE ----

@test "R4: an ISO date anywhere in the file fails" {
  write_agent "$FIX/agents/dated.md" dated
  echo "Introduced 2026-01-15 after a review miss." >> "$FIX/agents/dated.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/dated.md: R4:"* ]]
  [[ "$output" == *"2026-01-15"* ]]
  [[ "$output" != *"agents/dated.md: R5:"* ]]
}

@test "R4: the message names the date even when it sits past the excerpt cut" {
  write_agent "$FIX/agents/late-date.md" late-date
  # The date starts well past column 70, so a column-1 `cut -c1-70` excerpt
  # cannot contain it. Before the fix the message read "R4: ISO date at line
  # N: <70 chars with no date in them>".
  echo "| Asserting a downstream-consumer claim from a partial read | Concluding on 2026-07-09 |" \
    >> "$FIX/agents/late-date.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *'R4: ISO date "2026-07-09" at line'* ]]
  # Exactly one occurrence: the quoted token. The excerpt does NOT carry it,
  # which is precisely why quoting it is load-bearing.
  [ "$(occurrences '2026-07-09')" -eq 1 ]
}

@test "R4: two dates on one line still emit ONE well-formed message" {
  # `grep -oEm1` bounds matching LINES, not matches — `-o` still prints every
  # match on the line it stops at. A line carrying two dates therefore put a
  # NEWLINE inside the quoted token and split the message across two output
  # lines, the second of which had lost its `R4: ISO date "` prefix entirely.
  # Caught in CI's whole-tree run against agents/technician.md, not by any test.
  write_agent "$FIX/agents/two-dates.md" two-dates
  echo 'Retired 2026-07-15 and again 2026-07-03 for good measure.' \
    >> "$FIX/agents/two-dates.md"
  lint
  [ "$status" -eq 1 ]
  # The token is the FIRST date, quoted, with no newline smuggled in.
  [[ "$output" == *'R4: ISO date "2026-07-15" at line'* ]]
  # Exactly ONE R4 record — the split emitted a second, prefix-less line.
  [ "$(occurrences 'R4:')" -eq 1 ]
  # No finding line begins with a bare date: that is the orphan continuation
  # the newline produced. (The multi-line failure epilogue is legitimate and
  # deliberately not counted here — an earlier version of this test counted it
  # and failed against correct code.)
  local orphans
  orphans="$(printf '%s\n' "$output" | grep -cE '^[[:space:]]*20[0-9]{2}-[0-9]{2}-[0-9]{2}' || true)"
  [ "$orphans" -eq 0 ]
}

# ---- R5 NO-ISSUEREF ----

@test "R5: an issue/PR reference anywhere in the file fails" {
  write_agent "$FIX/agents/reffed.md" reffed
  echo "Per the discussion on #4242, always re-read the brief." >> "$FIX/agents/reffed.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/reffed.md: R5:"* ]]
  [[ "$output" == *"#4242"* ]]
  [[ "$output" != *"agents/reffed.md: R4:"* ]]
}

@test "R5: a parenthesised issue ref fails" {
  write_agent "$FIX/agents/paren-ref.md" paren-ref
  echo "Reported in the tracker (#4242) and never fixed." >> "$FIX/agents/paren-ref.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/paren-ref.md: R5:"* ]]
  [[ "$output" == *'"#4242"'* ]]
}

@test "R5: an ordinary markdown anchor link is NOT an issue ref" {
  write_agent "$FIX/agents/anchored.md" anchored
  # AGENT_TEMPLATE.md tells agent files to point at procedures, and deep-linking
  # a numbered heading is how that is written. This must not fire.
  echo "Follow [step 3](#3-verify-the-gate) before reporting." >> "$FIX/agents/anchored.md"
  lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"R5"* ]]
  [[ "$output" == *"agent-lint: linted 2 file(s)"* ]]
}

@test "R5: several anchor links on one line all pass" {
  write_agent "$FIX/agents/multi-anchor.md" multi-anchor
  echo "See [step 3](#3-verify) then [step 12](#12-report) and stop." \
    >> "$FIX/agents/multi-anchor.md"
  lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"R5"* ]]
}

@test "R5: an anchor link does not mask a real issue ref on the same line" {
  write_agent "$FIX/agents/mixed.md" mixed
  echo "See [step 3](#3-verify) — regression from #4242." >> "$FIX/agents/mixed.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/mixed.md: R5:"* ]]
  [[ "$output" == *'"#4242"'* ]]
}

@test "R5: a link whose fragment is purely digits still fails (rule not weakened)" {
  write_agent "$FIX/agents/digit-frag.md" digit-frag
  echo "See [the issue](#4242) for context." >> "$FIX/agents/digit-frag.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/digit-frag.md: R5:"* ]]
  [[ "$output" == *'"#4242"'* ]]
}

@test "R5: the message names the ref even when it sits past the excerpt cut" {
  write_agent "$FIX/agents/late-ref.md" late-ref
  echo "| Asserting a downstream-consumer claim from a partial read | See #4242 |" \
    >> "$FIX/agents/late-ref.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *'R5: issue/PR reference "#4242" at line'* ]]
  [ "$(occurrences '#4242')" -eq 1 ]
}

# ---- grandfathering: a listed violator WARNS ----

@test "a .lint-legacy-listed violator warns and does not fail" {
  write_agent "$FIX/agents/legacy-bad.md" legacy-bad
  sed -i 's/^# Boundaries$/# Limits/' "$FIX/agents/legacy-bad.md"
  echo "agents/legacy-bad.md" > "$FIX/agents/.lint-legacy"
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"agents/legacy-bad.md: R3:"* ]]
  [[ "$output" == *"grandfathered"* ]]
  [[ "$output" != *"❌"* ]]
}

# ---- L2 RATCHET: the list is shrink-only ----

@test "L2: a .lint-legacy entry that now conforms is a hard fail" {
  # good.md passes every hard rule, so its line must be deleted.
  echo "agents/good.md" > "$FIX/agents/.lint-legacy"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/good.md: L2:"* ]]
  [[ "$output" == *"now passes every hard rule"* ]]
  [[ "$output" == *"delete its line"* ]]
}

@test "L2: the ratchet predicate discriminates on R-records, not on stdout emptiness" {
  # Same tree, two listed files. The predicate must answer "has violations"
  # per file — a multi-finding violator stays grandfathered (no L2) while the
  # conforming one graduates (L2). If the predicate were 'is stdout empty' it
  # would be at the mercy of every line the formatter ever prints.
  write_agent "$FIX/agents/legacy-bad.md" legacy-bad
  sed -i 's/^# Role$/# Purpose/;s/^# Boundaries$/# Limits/' "$FIX/agents/legacy-bad.md"
  echo "Dated 2026-01-15 and filed as #4242." >> "$FIX/agents/legacy-bad.md"
  printf 'agents/legacy-bad.md\nagents/good.md\n' > "$FIX/agents/.lint-legacy"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/good.md: L2:"* ]]
  [[ "$output" != *"agents/legacy-bad.md: L2:"* ]]
  [[ "$output" == *"agents/legacy-bad.md: R2:"* ]]
  [[ "$output" == *"agents/legacy-bad.md: R4:"* ]]
}

# ---- L1 STALE: a listed path that does not exist ----

@test "L1: a stale .lint-legacy entry is a hard fail" {
  echo "agents/deleted-agent.md" > "$FIX/agents/.lint-legacy"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/deleted-agent.md: L1:"* ]]
  [[ "$output" == *"does not exist"* ]]
}

@test ".lint-legacy comments and blank lines are ignored" {
  cat > "$FIX/agents/.lint-legacy" <<'EOF'
# agents/this-is-a-comment-not-an-entry.md

# another comment
EOF
  lint
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}

# ---- the failure epilogue matches what actually failed ----

@test "epilogue: an L1-only failure does not recite the R-rule contract" {
  echo "agents/deleted-agent.md" > "$FIX/agents/.lint-legacy"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/deleted-agent.md: L1:"* ]]
  [[ "$output" != *"needs name:/description: frontmatter"* ]]
  [[ "$output" == *"Fix the findings above"* ]]
}

@test "epilogue: an R-rule failure DOES recite the R-rule contract" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs name:/description: frontmatter"* ]]
}

# ---- targeted mode still runs the legacy-list checks ----

@test "targeted mode: the .lint-legacy stale check still runs" {
  echo "agents/deleted-agent.md" > "$FIX/agents/.lint-legacy"
  lint agents/good.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/deleted-agent.md: L1:"* ]]
}

@test "targeted mode: the .lint-legacy ratchet check still runs" {
  write_agent "$FIX/agents/other.md" other
  echo "agents/other.md" > "$FIX/agents/.lint-legacy"
  lint agents/good.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/other.md: L2:"* ]]
}

@test "targeted mode: a violating file passed by path fails" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"
  lint agents/no-role.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/no-role.md: R2:"* ]]
}

@test "targeted mode: a violating file NOT passed is not reported" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"
  lint agents/good.md
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}

# ---- CODEX_SNAPSHOT=1 downgrades hard failures ----

@test "CODEX_SNAPSHOT=1 downgrades a hard failure to a warn and exits 0" {
  write_agent "$FIX/agents/no-role.md" no-role
  sed -i 's/^# Role$/# Purpose/' "$FIX/agents/no-role.md"

  # Same tree, authoring profile: hard fail. (Proves the fixture can fail —
  # otherwise the snapshot assertion below tests nothing.)
  lint
  [ "$status" -eq 1 ]

  run env LINT_AGENT_FILES_ROOT="$FIX" CODEX_SNAPSHOT=1 bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"codex-snapshot"* ]]
  [[ "$output" == *"agents/no-role.md: R2:"* ]]
  [[ "$output" != *"❌"* ]]
}

@test "CODEX_SNAPSHOT=1 downgrades the L1 stale-entry failure too" {
  echo "agents/deleted-agent.md" > "$FIX/agents/.lint-legacy"
  run env LINT_AGENT_FILES_ROOT="$FIX" CODEX_SNAPSHOT=1 bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/deleted-agent.md: L1:"* ]]
  [[ "$output" == *"codex-snapshot"* ]]
}

@test "CODEX_SNAPSHOT=1 downgrades the targeted-mode missing-target failure too" {
  run env LINT_AGENT_FILES_ROOT="$FIX" CODEX_SNAPSHOT=1 bash "$SCRIPT" agents/nope.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/nope.md: named target does not exist"* ]]
  [[ "$output" == *"codex-snapshot"* ]]
}

# ---- W1 SIZE BUDGET (warn only) ----

@test "W1: a reviewer over the 80-line budget warns without failing" {
  write_agent "$FIX/agents/big-reviewer.md" big-reviewer
  pad "$FIX/agents/big-reviewer.md" 80
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/big-reviewer.md: W1:"* ]]
  [[ "$output" == *"80-line reviewer budget"* ]]
  [[ "$output" != *"❌"* ]]
}

@test "W1: a non-reviewer of the same size is under its 150-line budget" {
  write_agent "$FIX/agents/big-agent.md" big-agent
  pad "$FIX/agents/big-agent.md" 80
  lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"agents/big-agent.md: W1:"* ]]
}

@test "W1: a non-reviewer over the 150-line budget warns without failing" {
  write_agent "$FIX/agents/huge-agent.md" huge-agent
  pad "$FIX/agents/huge-agent.md" 200
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/huge-agent.md: W1:"* ]]
  [[ "$output" == *"150-line agent budget"* ]]
}

@test "W1: a reviewer AT exactly 80 lines does not warn" {
  # Pins the `-gt` boundary. An off-by-one to `-ge` passes every other W1 test.
  write_agent "$FIX/agents/edge-reviewer.md" edge-reviewer
  grow_to "$FIX/agents/edge-reviewer.md" 80
  [ "$(awk 'END{print NR}' "$FIX/agents/edge-reviewer.md")" -eq 80 ]
  lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"agents/edge-reviewer.md: W1:"* ]]
}

@test "W1: a reviewer at 81 lines — one over — warns" {
  write_agent "$FIX/agents/edge-reviewer.md" edge-reviewer
  grow_to "$FIX/agents/edge-reviewer.md" 81
  [ "$(awk 'END{print NR}' "$FIX/agents/edge-reviewer.md")" -eq 81 ]
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/edge-reviewer.md: W1: 81 lines over the 80-line reviewer budget"* ]]
}

@test "W1: a non-reviewer AT exactly 150 lines does not warn" {
  write_agent "$FIX/agents/edge-agent.md" edge-agent
  grow_to "$FIX/agents/edge-agent.md" 150
  lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"agents/edge-agent.md: W1:"* ]]
}

@test "W1: a non-reviewer at 151 lines — one over — warns" {
  write_agent "$FIX/agents/edge-agent.md" edge-agent
  grow_to "$FIX/agents/edge-agent.md" 151
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/edge-agent.md: W1: 151 lines over the 150-line agent budget"* ]]
}

# ---- W1 class detection must not be permissive on malformed frontmatter ----

@test "W1: a folded-scalar name: still gets the reviewer budget" {
  # `name: >-` makes fm_value return the YAML block-scalar indicator, which
  # never matched *-reviewer — the file silently got the 150-line budget.
  cat > "$FIX/agents/folded-reviewer.md" <<'EOF'
---
name: >-
  folded-reviewer
description: "Name written as a folded scalar."
model: sonnet
---

# Role

Reviews.

# Boundaries

Nothing else.
EOF
  grow_to "$FIX/agents/folded-reviewer.md" 100
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/folded-reviewer.md: W1: 100 lines over the 80-line reviewer budget"* ]]
}

@test "W1: an absent name: falls back to the filename for the budget class" {
  cat > "$FIX/agents/absent-reviewer.md" <<'EOF'
---
description: "No name key at all."
model: sonnet
---

# Role

Reviews.

# Boundaries

Nothing else.
EOF
  grow_to "$FIX/agents/absent-reviewer.md" 100
  lint
  # R1 hard-fails on the missing name:, but the SIZE class must still be right.
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents/absent-reviewer.md: W1: 100 lines over the 80-line reviewer budget"* ]]
}

@test "W1: a quoted multi-word name: falls back to the filename for the budget class" {
  cat > "$FIX/agents/quoted-reviewer.md" <<'EOF'
---
name: "quoted reviewer"
description: "Name is a quoted multi-word value."
model: sonnet
---

# Role

Reviews.

# Boundaries

Nothing else.
EOF
  grow_to "$FIX/agents/quoted-reviewer.md" 100
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/quoted-reviewer.md: W1: 100 lines over the 80-line reviewer budget"* ]]
}

@test "W1: an unreadable file reports it instead of leaking shell noise" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 does not restrict root"
  write_agent "$FIX/agents/unreadable.md" unreadable
  chmod 000 "$FIX/agents/unreadable.md"
  lint
  [[ "$output" != *"integer expression expected"* ]]
  [[ "$output" == *"agents/unreadable.md: W1: cannot read the file"* ]]
}

# ---- W2 MODEL (warn only) ----

@test "W2: missing model: warns without failing" {
  write_agent "$FIX/agents/no-model.md" no-model
  sed -i '/^model: /d' "$FIX/agents/no-model.md"
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents/no-model.md: W2:"* ]]
  [[ "$output" != *"❌"* ]]
}

# ---- scope: what the linter does NOT lint ----

@test "agents/EVOLUTION.md is excluded from the lint" {
  cat > "$FIX/agents/EVOLUTION.md" <<'EOF'
# Evolution log

2026-01-15 — reworded the roster entry, see #4242.
EOF
  lint
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}

@test "a nested agents/**/x.md is not linted" {
  mkdir -p "$FIX/agents/sub"
  cat > "$FIX/agents/sub/notes.md" <<'EOF'
Nested note with no frontmatter, no Role, no Boundaries.
EOF
  lint
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lint: linted 1 file(s)" ]
}
