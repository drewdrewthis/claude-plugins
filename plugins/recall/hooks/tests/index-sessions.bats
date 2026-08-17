#!/usr/bin/env bats
# Tests for hooks/index-sessions.sh — the SessionEnd indexer refresh.
#
# Upstream this hook lived in the codex, hardcoded ~/.claude/scripts/, and was
# never registered in settings.json, so it had never fired once. These tests pin
# the two properties that made it dead weight there: it must invoke the BUNDLED
# script (via CLAUDE_PLUGIN_ROOT, not an absolute codex path), and it must be
# declared for a real event in hooks.json.
#
# The hook backgrounds its work and silences all output by design (ADR-001:
# hooks fail open), so the observable contract is "the index advances", not an
# exit code — a hook asserted on $? would pass while indexing nothing.
#
# Run: bats hooks/tests/index-sessions.bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$PLUGIN_ROOT/hooks/index-sessions.sh"
  FIX="$(mktemp -d)"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export SESSION_INDEX_PROJECTS="$FIX/projects"
  export SESSION_INDEX_DB="$FIX/sessions.db"
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# Block until the index holds $1 rows, or fail after ~5s. The hook detaches its
# work with `&` and then exits, so the indexer is orphaned from this shell —
# `wait` returns immediately and has nothing to wait on. Polling is the only
# honest way to observe a deliberately-backgrounded hook; a bare assert right
# after the call passes or fails on scheduler luck.
await_rows() {
  local want="$1" i
  for i in $(seq 1 50); do
    [ "$(count_rows)" -eq "$want" ] && return 0
    sleep 0.1
  done
  echo "index never reached $want rows (last: $(count_rows))" >&2
  return 1
}

count_rows() {
  python3 -c "
import sqlite3, sys
try:
    print(sqlite3.connect('$SESSION_INDEX_DB').execute('select count(*) from sessions').fetchone()[0])
except sqlite3.OperationalError:
    print(0)"
}

write_session() {
  python3 -c "
import json
with open('$SESSION_INDEX_PROJECTS/-home-me-proj/$1.jsonl', 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'content': '$2'}}) + '\n')"
}

@test "the hook resolves the bundled script, not an absolute codex path" {
  grep -q 'CLAUDE_PLUGIN_ROOT' "$HOOK"
  ! grep -q '~/.claude/scripts' "$HOOK"
  ! grep -q '/home/' "$HOOK"
}

@test "the script the hook points at actually exists" {
  # Resolve the path OUT of the hook rather than asserting a path the test
  # already knows: `claude plugin validate` never stats a hook's target, so a
  # hook referencing a missing script ships green unless something checks here.
  local ref
  ref="$(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[^"]+\.py' "$HOOK")"
  [ -n "$ref" ]
  [ -f "${ref/\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}" ]
}

@test "every script path SKILL.md invokes resolves to a real file" {
  # Same contract as the hook test above, applied to the skill: resolve the path
  # OUT of the artifact rather than asserting one the test already knows. The
  # script moved from ${CLAUDE_SKILL_DIR}/scripts to plugin root so the skill and
  # the hook share one copy; nothing but this would catch a stale reference.
  local ref found=0
  while read -r ref; do
    found=1
    [ -f "${ref/\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}" ]
  done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[^ "]+\.py' "$PLUGIN_ROOT/skills/recall/SKILL.md" | sort -u)
  [ "$found" -eq 1 ]
  # The old skill-relative form must not survive the move.
  ! grep -q 'CLAUDE_SKILL_DIR' "$PLUGIN_ROOT/skills/recall/SKILL.md"
}

@test "hooks.json declares the hook for SessionEnd" {
  run python3 -c "
import json
h = json.load(open('$PLUGIN_ROOT/hooks/hooks.json'))['hooks']
assert list(h) == ['SessionEnd'], list(h)
cmd = h['SessionEnd'][0]['hooks'][0]['command']
assert 'index-sessions.sh' in cmd, cmd
assert 'CLAUDE_PLUGIN_ROOT' in cmd, cmd
print('ok')"
  [ "$status" -eq 0 ]
}

@test "running the hook advances the index" {
  write_session "aaa" "a first conversation worth indexing here"
  [ "$(count_rows)" -eq 0 ]
  bash "$HOOK"
  await_rows 1
}

@test "the hook picks up a transcript added after the first run" {
  write_session "aaa" "a first conversation worth indexing here"
  bash "$HOOK"
  await_rows 1
  write_session "bbb" "a second conversation worth indexing here"
  bash "$HOOK"
  await_rows 2
}

@test "the hook stays silent and fails open when the index path is unwritable" {
  export SESSION_INDEX_DB="/proc/nonexistent/sessions.db"
  run bash "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
