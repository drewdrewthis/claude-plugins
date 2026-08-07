#!/usr/bin/env bats
# Tests for skills/recall/scripts/session-index.py — the transcript search index.
#
# Every test points SESSION_INDEX_PROJECTS and SESSION_INDEX_DB at a mktemp
# fixture, so the host's real ~/.claude/projects is NEVER read and no index is
# written outside the fixture. That isolation IS the plugin adaptation under
# test: upstream the script hardcoded `~/.claude`, and installed as a plugin it
# must not write into the plugin dir or assume the config dir's location.
#
# Coverage map:
#   build    indexes fixture transcripts, is incremental, prunes deleted ones
#   search   matches on user text, honours --limit, errors on an empty index
#   context  dumps the tail of one transcript
#   roots    CLAUDE_CONFIG_DIR resolves both paths; the per-path vars override it
#   decode   project dir names round-trip, including hidden dirs (no host literal)
#
# Run: bats skills/recall/scripts/tests/session-index.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../session-index.py"
  FIX="$(mktemp -d)"
  export SESSION_INDEX_PROJECTS="$FIX/projects"
  export SESSION_INDEX_DB="$FIX/sessions.db"
  mkdir -p "$SESSION_INDEX_PROJECTS"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# Write a fixture transcript. $1 = project dir, $2 = session id, rest = user texts.
write_session() {
  local project="$1" sid="$2"; shift 2
  mkdir -p "$SESSION_INDEX_PROJECTS/$project"
  local f="$SESSION_INDEX_PROJECTS/$project/$sid.jsonl"
  : >"$f"
  local text
  for text in "$@"; do
    python3 - "$f" "$text" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
with open(path, "a") as fh:
    fh.write(json.dumps({"type": "user", "message": {"content": text}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {"content": "ack " + text}}) + "\n")
PY
  done
}

@test "build indexes fixture transcripts and reports the count" {
  write_session "-home-me-proj" "aaa" "we decided to use the porter tokenizer for search"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==1, d; assert d["total"]==1, d'
}

@test "build writes the db to SESSION_INDEX_DB, not into the plugin dir" {
  write_session "-home-me-proj" "aaa" "some indexable conversation text here"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$SESSION_INDEX_DB" ]
  [ ! -e "$BATS_TEST_DIRNAME/../sessions.db" ]
}

@test "build is incremental — an unchanged transcript is skipped, not re-parsed" {
  write_session "-home-me-proj" "aaa" "some indexable conversation text here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==0, d; assert d["skipped"]==1, d'
}

@test "build prunes sessions whose transcript was deleted" {
  write_session "-home-me-proj" "aaa" "some indexable conversation text here"
  write_session "-home-me-proj" "bbb" "another indexable conversation text here"
  python3 "$SCRIPT" build >/dev/null
  rm "$SESSION_INDEX_PROJECTS/-home-me-proj/bbb.jsonl"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["removed"]==1, d; assert d["total"]==1, d'
}

@test "search finds a session by its user text and returns its file path" {
  write_session "-home-me-proj" "aaa" "we chose the porter tokenizer for the index"
  write_session "-home-me-proj" "bbb" "unrelated chatter about breakfast options"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "porter"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert r[0]["session_id"] == "aaa", r
assert r[0]["file_path"].endswith("aaa.jsonl"), r'
}

@test "search honours --limit" {
  write_session "-home-me-proj" "aaa" "tokenizer discussion number one here"
  write_session "-home-me-proj" "bbb" "tokenizer discussion number two here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --limit 1
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1'
}

@test "search on an empty index errors rather than reporting no results" {
  run python3 "$SCRIPT" search "anything"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Index is empty"
}

@test "context dumps the tail of one transcript" {
  write_session "-home-me-proj" "aaa" "first substantive message in the session" "second substantive message here"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --tail 2
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
m = json.load(sys.stdin)
assert len(m) == 2, m
assert m[-1]["text"].startswith("ack second"), m'
}

@test "CLAUDE_CONFIG_DIR relocates both the projects dir and the db" {
  local alt="$FIX/alt"
  unset SESSION_INDEX_PROJECTS SESSION_INDEX_DB
  export CLAUDE_CONFIG_DIR="$alt"
  mkdir -p "$alt/projects/-home-me-proj"
  export SESSION_INDEX_PROJECTS="$alt/projects"
  write_session "-home-me-proj" "aaa" "relocated config dir conversation text"
  unset SESSION_INDEX_PROJECTS
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$alt/sessions.db" ]
  echo "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["total"]==1'
}

@test "the per-path vars win over CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$FIX/ignored"
  write_session "-home-me-proj" "aaa" "per path override conversation text here"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$SESSION_INDEX_DB" ]
  [ ! -e "$FIX/ignored/sessions.db" ]
}

@test "search decodes a hidden project dir without a host-specific literal" {
  write_session "-home-me--claude" "aaa" "conversation inside a dotted config dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "dotted"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["project"] == "/home/me/.claude", r[0]["project"]'
}

@test "search renders a project under the real home as a ~ path" {
  local encoded="${HOME//\//-}-recallfixture"
  write_session "$encoded" "aaa" "conversation stored beneath the real home dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "beneath"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["project"] == "~/recallfixture", r[0]["project"]'
}
