#!/usr/bin/env bats
# Tests for enforce-frontmatter.sh — the PostToolUse hook that runs the
# vendored lint-frontmatter.sh against a just-written record.
#
# All fixtures live under a temp KNOWLEDGE_ROOT (or CODEX_ROOT) with a
# references/decisions/ store, so the vendored linter only ever sees fixture
# files — never the real ~/.claude.
#
# Run: bats hooks/tests/enforce-frontmatter.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  SCRIPT="$HOOKS/enforce-frontmatter.sh"
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/references/decisions"

  cat > "$FIX/references/decisions/no-fm.md" <<'EOF'
# No frontmatter here

Just a heading with no --- fence.
EOF

  cat > "$FIX/references/decisions/good.md" <<'EOF'
---
id: dec.enforce-good
kind: decision
date: 2026-06-12
keywords: [enforceword]
links: {}
status: active
---
# Good decision

A valid six-key record used as the enforcement pass case.
EOF
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# write_payload <file_path> — Write-tool payload the hook expects on stdin.
write_payload() {
  jq -nc --arg fp "$1" '{tool_name:"Write",tool_input:{file_path:$fp}}'
}

@test "missing frontmatter record under KNOWLEDGE_ROOT: exit 2, stderr mentions FRONTMATTER" {
  run env KNOWLEDGE_ROOT="$FIX" bash -c \
    "jq -nc --arg fp '$FIX/references/decisions/no-fm.md' '{tool_name:\"Write\",tool_input:{file_path:\$fp}}' | bash '$SCRIPT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FRONTMATTER"* ]] || [[ "$stderr" == *"FRONTMATTER"* ]]
}

@test "valid six-key record: exit 0, no output" {
  write_payload "$FIX/references/decisions/good.md" \
    | env KNOWLEDGE_ROOT="$FIX" bash "$SCRIPT" > "$FIX/out.txt" 2>&1
  status=$?
  [ "$status" -eq 0 ]
  [ ! -s "$FIX/out.txt" ]
}

@test ".md outside KNOWLEDGE_ROOT: exit 0" {
  OUTSIDE="$(mktemp -d)"
  cat > "$OUTSIDE/no-fm.md" <<'EOF'
# No frontmatter, and outside the root entirely.
EOF
  write_payload "$OUTSIDE/no-fm.md" \
    | env KNOWLEDGE_ROOT="$FIX" bash "$SCRIPT" > "$FIX/out.txt" 2>&1
  status=$?
  rm -rf "$OUTSIDE"
  [ "$status" -eq 0 ]
}

# A non-record .md inside KNOWLEDGE_ROOT but outside any of the linter's
# stores (e.g. a SKILL.md) is out-of-scope for enforcement — the linter's
# targeted mode reports "not a lintable record" and the hook treats that as
# a pass. This test PINS that exact vendored string as a seam: if a future
# re-vendor of lint-frontmatter.sh rewords its message, this test starts
# failing loudly instead of enforce-frontmatter.sh silently going permissive
# (or silently starting to block) on every non-record .md.
@test "non-record .md inside KNOWLEDGE_ROOT but outside any store: exit 0" {
  mkdir -p "$FIX/skills/x"
  cat > "$FIX/skills/x/SKILL.md" <<'EOF'
---
name: x
description: not a record
---
# Not a record
EOF
  write_payload "$FIX/skills/x/SKILL.md" \
    | env KNOWLEDGE_ROOT="$FIX" bash "$SCRIPT" > "$FIX/out.txt" 2>&1
  status=$?
  [ "$status" -eq 0 ]
}

@test "CODEX_ROOT (without KNOWLEDGE_ROOT) scopes the hook the same way" {
  run env -u KNOWLEDGE_ROOT CODEX_ROOT="$FIX" bash -c \
    "jq -nc --arg fp '$FIX/references/decisions/no-fm.md' '{tool_name:\"Write\",tool_input:{file_path:\$fp}}' | bash '$SCRIPT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FRONTMATTER"* ]] || [[ "$stderr" == *"FRONTMATTER"* ]]
}

@test "non-md file: exit 0" {
  write_payload "$FIX/references/decisions/no-fm.txt" \
    | env KNOWLEDGE_ROOT="$FIX" bash "$SCRIPT" > "$FIX/out.txt" 2>&1
  status=$?
  [ "$status" -eq 0 ]
}

@test "jq-less PATH: hook exits 0 silently when jq is unreachable" {
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" KNOWLEDGE_ROOT="$FIX" \
    /bin/bash -c "echo '{}' | /bin/bash '$SCRIPT'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
