#!/usr/bin/env bats
# Tests for scripts/session-index.py — the transcript search index.
#
# Every test points SESSION_INDEX_PROJECTS and SESSION_INDEX_DB at a mktemp
# fixture, so the host's real ~/.claude/projects is NEVER read and no index is
# written outside the fixture. That isolation IS the plugin adaptation under
# test: upstream the script hardcoded `~/.claude`, and installed as a plugin it
# must not write into the plugin dir or assume the config dir's location.
#
# Fixture project dirs deliberately contain hyphens inside path components
# (`-home-me-my-project`), because Claude Code's dir-name encoding maps `/` to
# `-` without escaping, and an earlier decoder was green only against fixtures
# built with no interior hyphen.
#
# Run: bats scripts/tests/session-index.bats

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

# write_session <project-dir> <session-id> <cwd-or-empty> <text>...
write_session() {
  local project="$1" sid="$2" cwd="$3"; shift 3
  mkdir -p "$SESSION_INDEX_PROJECTS/$project"
  local f="$SESSION_INDEX_PROJECTS/$project/$sid.jsonl"
  : >"$f"
  local text
  for text in "$@"; do
    python3 - "$f" "$text" "$cwd" <<'PY'
import json, sys
path, text, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
rec = {"type": "user", "message": {"content": text}}
if cwd:
    rec["cwd"] = cwd
with open(path, "a") as fh:
    fh.write(json.dumps(rec) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {"content": "ack " + text}}) + "\n")
PY
  done
}

@test "build indexes fixture transcripts and reports the count" {
  write_session "-home-me-proj" "aaa" "/home/me/proj" "we decided to use the porter tokenizer"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==1, d; assert d["total"]==1, d'
}

@test "build writes the db to SESSION_INDEX_DB, not into the plugin dir" {
  write_session "-home-me-proj" "aaa" "" "some indexable conversation text here"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$SESSION_INDEX_DB" ]
  [ ! -e "$BATS_TEST_DIRNAME/../sessions.db" ]
}

@test "the index db is not world-readable" {
  write_session "-home-me-proj" "aaa" "" "some indexable conversation text here"
  python3 "$SCRIPT" build >/dev/null
  run stat -c '%a' "$SESSION_INDEX_DB"
  [ "$output" = "600" ]
}

@test "build is incremental — an unchanged transcript is skipped" {
  write_session "-home-me-proj" "aaa" "" "some indexable conversation text here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" build
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==0, d; assert d["skipped"]==1, d'
}

@test "a rewrite that preserves mtime is still re-indexed" {
  # rsync -a / cp -p / a restore all reproduce this; mtime alone misses it.
  local f="$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl"
  write_session "-home-me-proj" "aaa" "" "the original topic was zebras entirely"
  python3 "$SCRIPT" build >/dev/null
  touch -r "$f" "$FIX/ref"
  write_session "-home-me-proj" "aaa" "" "the replacement topic is penguins entirely and then some"
  touch -r "$FIX/ref" "$f"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "penguins"
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1, "same-mtime rewrite went unindexed"'
}

@test "build prunes sessions whose transcript was deleted" {
  write_session "-home-me-proj" "aaa" "" "some indexable conversation text here"
  write_session "-home-me-proj" "bbb" "" "another indexable conversation text here"
  python3 "$SCRIPT" build >/dev/null
  rm "$SESSION_INDEX_PROJECTS/-home-me-proj/bbb.jsonl"
  run python3 "$SCRIPT" build
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["removed"]==1, d; assert d["total"]==1, d'
}

@test "one unreadable transcript does not abort the build" {
  # A dangling symlink stands in for the real trigger: a transcript pruned
  # between the glob and the stat. Aborting discarded every session already
  # parsed, and since nothing was committed, every later build died identically.
  write_session "-home-me-proj" "aaa" "" "a perfectly good conversation here"
  write_session "-home-me-proj" "bbb" "" "a second perfectly good conversation"
  ln -s "$FIX/nonexistent.jsonl" "$SESSION_INDEX_PROJECTS/-home-me-proj/zzz.jsonl"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==2, d; assert d["failed"]==1, d'
}

@test "two sessions sharing an id under different projects both survive" {
  write_session "-home-me-alpha" "dup" "/home/me/alpha" "the alphaland conversation text"
  write_session "-home-me-beta"  "dup" "/home/me/beta"  "the betaville conversation text"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "alphaland OR betaville"
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==2, "a session id collision dropped one"'
}

@test "search finds a session by its user text and returns its file path" {
  write_session "-home-me-proj" "aaa" "" "we chose the porter tokenizer for the index"
  write_session "-home-me-proj" "bbb" "" "unrelated chatter about breakfast options"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "porter"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert r[0]["session_id"] == "aaa", r
assert r[0]["file_path"].endswith("aaa.jsonl"), r'
}

@test "search honours --limit" {
  write_session "-home-me-proj" "aaa" "" "tokenizer discussion number one here"
  write_session "-home-me-proj" "bbb" "" "tokenizer discussion number two here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --limit 1
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1'
}

@test "a hyphenated search term returns results, not a traceback" {
  # FTS5 reads its input as a query language: unquoted `pr-ready-check` parses
  # as a column filter and raised OperationalError. Hyphenated identifiers are
  # the most likely thing anyone types.
  write_session "-home-me-proj" "aaa" "" "we fixed the pr-ready-check gate today"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "pr-ready-check"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1, "hyphenated term found nothing"'
}

@test "punctuation in a query never produces a traceback" {
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics here"
  python3 "$SCRIPT" build >/dev/null
  local q
  for q in "don't break" 'unbalanced "quote' 'paren (open' '*' 'C++ design' 'foo:bar' 'judge OR'; do
    run python3 "$SCRIPT" search "$q"
    [[ "$output" != *"Traceback"* ]] || { echo "traceback on query: $q"; return 1; }
    echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' \
      || { echo "non-JSON output on query: $q"; return 1; }
  done
}

@test "a union containing a hyphenated synonym still searches" {
  write_session "-home-me-proj" "aaa" "" "notes on the quorum design meeting"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "well-known OR quorum"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1'
}

@test "an empty index reports a clean JSON error, not a traceback" {
  run python3 "$SCRIPT" search "anything"
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)'
}

@test "context returns the tail of one transcript" {
  write_session "-home-me-proj" "aaa" "" "first substantive message in the session" "second substantive message here"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --tail 2
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
m = json.load(sys.stdin)
assert len(m) == 2, m
assert m[-1]["text"].startswith("ack second"), m'
}

@test "context refuses a path outside the transcripts directory" {
  write_session "-home-me-proj" "aaa" "" "a conversation to make the index non-empty"
  run python3 "$SCRIPT" context /etc/passwd
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)'
}

@test "context reports a missing file as a JSON error" {
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/nope.jsonl"
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)'
}

@test "a system-reminder at the START of a message is stripped" {
  # The guard used `idx > 0`, so it never fired on the shape that occurs:
  # reminders lead the message.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 -c "
import json
p = '$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl'
with open(p,'w') as f:
    f.write(json.dumps({'type':'user','message':{'content':'<system-reminder>noise noise</system-reminder>'}})+'\n')
    f.write(json.dumps({'type':'user','message':{'content':'the genuine question I asked'}})+'\n')"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl"
  echo "$output" | python3 -c '
import json,sys
m = json.load(sys.stdin)
assert not any("noise" in x["text"] for x in m), m'
}

@test "non-UTF-8 bytes do not silently drop a whole transcript" {
  # Under LC_ALL=C the locale default raised UnicodeDecodeError, which the
  # per-file guard swallowed — the index came up near-empty with no signal.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 -c "
import json
p = '$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl'
with open(p,'wb') as f:
    f.write(json.dumps({'type':'user','message':{'content':'la décision du café naïve'}}).encode('utf-8')+b'\n')"
  LC_ALL=C run python3 "$SCRIPT" build
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==1, d; assert d["failed"]==0, d'
}

@test "CLAUDE_CONFIG_DIR relocates both the projects dir and the db" {
  local alt="$FIX/alt"
  export CLAUDE_CONFIG_DIR="$alt"
  mkdir -p "$alt/projects"
  export SESSION_INDEX_PROJECTS="$alt/projects"
  write_session "-home-me-proj" "aaa" "" "relocated config dir conversation text"
  unset SESSION_INDEX_PROJECTS SESSION_INDEX_DB
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$alt/sessions.db" ]
  echo "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["total"]==1'
}

@test "the per-path vars win over CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$FIX/ignored"
  write_session "-home-me-proj" "aaa" "" "per path override conversation text here"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [ -f "$SESSION_INDEX_DB" ]
  [ ! -e "$FIX/ignored/sessions.db" ]
}

@test "a hit's project is the session's real cwd, hyphens and all" {
  # The decisive case: the dir name encodes `/` as `-` without escaping, so
  # `-home-me-my-project` is ambiguous. The recorded cwd is the only truth.
  write_session "-home-me-my-project" "aaa" "/home/me/my-project" "conversation inside a hyphenated repo"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "hyphenated"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["project"] == "/home/me/my-project", r[0]["project"]'
}

@test "a hidden directory in the cwd survives intact" {
  write_session "-home-me--claude" "aaa" "/home/me/.claude" "conversation inside a dotted config dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "dotted"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["project"] == "/home/me/.claude", r[0]["project"]'
}

@test "a cwd under the real home renders as a ~ path" {
  write_session "-fixture-proj" "aaa" "$HOME/recall-fixture" "conversation beneath the real home dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "beneath"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["project"] == "~/recall-fixture", r[0]["project"]'
}

@test "with no recorded cwd the raw dir name is returned, never a fabricated path" {
  write_session "-home-me-my-project" "aaa" "" "conversation with no cwd recorded anywhere"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "fabricated OR conversation"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
# The encoded name verbatim — NOT "/home/me/my/project", which does not exist.
assert r[0]["project"] == "-home-me-my-project", r[0]["project"]'
}
