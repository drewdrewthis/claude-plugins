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

# Rows in the index right now, or 0 if there is no readable table.
row_count() {
  python3 -c "
import sqlite3
try:
    print(sqlite3.connect('$SESSION_INDEX_DB').execute('select count(*) from sessions').fetchone()[0])
except sqlite3.OperationalError:
    print(0)"
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

@test "genuinely non-UTF-8 bytes do not drop a whole transcript" {
  # An earlier version of this test wrote json.dumps(...) which defaults to
  # ensure_ascii=True — pure ASCII on disk. It stayed green with the utf-8
  # handling removed entirely. This writes raw latin-1 bytes that are invalid
  # UTF-8, so errors="replace" is the only reason the record survives.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 -c "
import json
p = '$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl'
rec = json.dumps({'type':'user','message':{'content':'la decision du cafe naive PLACEHOLDER'}}, ensure_ascii=False)
raw = rec.replace('PLACEHOLDER', 'X').encode('utf-8').replace(b'X', b'\xe9\xef\xff')
open(p,'wb').write(raw + b'\n')"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==1, d; assert d["failed"]==0, d'
}

@test "an index from an older schema is rebuilt, not left broken" {
  # CREATE TABLE IF NOT EXISTS is a no-op against an existing table, so an old
  # index kept its columns and every query died on "no such column: size" —
  # forever, and silently, because the hook discards output.
  write_session "-home-me-proj" "aaa" "/home/me/proj" "a conversation worth finding again"
  python3 -c "
import sqlite3
db = sqlite3.connect('$SESSION_INDEX_DB')
db.execute('CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, file_path TEXT, mtime REAL, message_count INTEGER, first_prompt TEXT, last_prompt TEXT)')
db.execute(\"CREATE VIRTUAL TABLE sessions_fts USING fts5(session_id, project, user_text, tokenize='porter unicode61')\")
db.commit()"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["total"]==1, d'
  run python3 "$SCRIPT" search "conversation"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1'
}

@test "a malformed record is skipped without costing its transcript" {
  # `"message": null` and a text block missing its "text" key are both real
  # shapes. Asserting only "some other file still indexed" was vacuous — the
  # broad per-file guard absorbed the failure and the test passed with the
  # defensive parsing reverted. What must hold is that the offending FILE is
  # still indexed (failed==0), with only the bad record dropped.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 -c "
import json
p = '$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl'
with open(p,'w') as f:
    f.write(json.dumps({'type':'user','message':None})+chr(10))
    f.write(json.dumps({'type':'user','message':{'content':[{'type':'text'}]}})+chr(10))
    f.write(json.dumps({'type':'user','message':{'content':'the salvageable sentence in this transcript'}})+chr(10))"
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  [[ "$output" != *"Traceback"* ]]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["indexed"]==1, d; assert d["failed"]==0, d'
  run python3 "$SCRIPT" search "salvageable"
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1, "a malformed record cost the whole transcript"'
}

@test "NOT excludes rather than inverting the query" {
  # Stripping a leading operator turned `NOT running` into `"running"` — the
  # exact complement of what was asked.
  write_session "-home-me-proj" "aaa" "" "we were running the deployment script"
  write_session "-home-me-proj" "bbb" "" "we were running the pottery glazing"
  python3 "$SCRIPT" build >/dev/null
  # Positive direction: the binary form must still work and still exclude.
  run python3 "$SCRIPT" search "running NOT pottery"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert "deployment" in r[0]["snippet"], r'
  # Negative direction: a leading NOT is refused, never silently inverted.
  run python3 "$SCRIPT" search "NOT pottery"
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; assert "NOT" in json.load(sys.stdin)["error"]'
}

@test "a dangling or lone operator never silently empties the result" {
  # `running NEAR` returned 0 of 2 matching docs because NEAR was quoted as a
  # literal word. Same silent-wrong-answer class as the NOT inversion, found
  # only by enumerating the operator set rather than patching the reported one.
  write_session "-home-me-proj" "aaa" "" "we were running the deployment script"
  write_session "-home-me-proj" "bbb" "" "we were running the pottery glazing"
  python3 "$SCRIPT" build >/dev/null
  local q
  for q in "running NEAR" "running AND" "running OR" "AND running" "running AND AND pottery"; do
    run python3 "$SCRIPT" search "$q"
    [ "$status" -eq 0 ] || { echo "errored on: $q"; return 1; }
    echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert len(r) >= 1, "silently returned nothing"' || { echo "empty result for: $q"; return 1; }
  done
  # A query of operators alone has nothing to search for and says so.
  run python3 "$SCRIPT" search "NEAR"
  [ "$status" -eq 1 ]
}

@test "a skipped transcript is recorded where the hook path can be seen" {
  # The SessionEnd hook discards stdout and stderr, so the `failed` count in the
  # return value is invisible on the only automatic path.
  write_session "-home-me-proj" "aaa" "" "a perfectly good conversation here"
  ln -s "$FIX/nonexistent.jsonl" "$SESSION_INDEX_PROJECTS/-home-me-proj/zzz.jsonl"
  python3 "$SCRIPT" build >/dev/null 2>&1
  [ -f "$SESSION_INDEX_DB.log" ]
  grep -q "skipped 1 unreadable transcript" "$SESSION_INDEX_DB.log"
}

@test "a prefix term still matches" {
  # Quoting every token turned `kuber*` into a literal and silently killed
  # prefix search — a recall regression with no error to notice.
  write_session "-home-me-proj" "aaa" "" "notes on the kubernetes rollout plan"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "kuber*"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1, "prefix search returned nothing"'
}

@test "concurrent builds both complete without a lock error" {
  local i
  for i in $(seq 1 40); do write_session "-home-me-proj" "s$i" "" "conversation number $i about assorted topics"; done
  python3 "$SCRIPT" build >"$FIX/b1.out" 2>"$FIX/b1.err" &
  python3 "$SCRIPT" build >"$FIX/b2.out" 2>"$FIX/b2.err" &
  wait
  # BOTH streams. This grepped only .err and was therefore vacuous: the script
  # reports failure through fail(), which print()s to STDOUT, so the string it
  # was looking for could never appear where it was looking.
  if grep -l "database is locked" "$FIX"/b1.out "$FIX"/b1.err "$FIX"/b2.out "$FIX"/b2.err; then
    echo "lock error under concurrency (see the file listed above)" >&2
    return 1
  fi
  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
}

@test "concurrent builds survive a schema-version bump" {
  # The migration DROPs tables, and SQLite returns SQLITE_BUSY IMMEDIATELY for a
  # schema change — the busy timeout is not consulted — so two hooks racing a
  # version bump killed the loser ~4 runs in 5. The test above cannot catch it:
  # it races two builds at the SAME version, where no migration runs at all.
  local i
  for i in $(seq 1 40); do write_session "-home-me-proj" "s$i" "" "conversation number $i about assorted topics"; done
  python3 "$SCRIPT" build >/dev/null
  # Force the next open to migrate, exactly as a real version bump would.
  python3 -c "import sqlite3; d=sqlite3.connect('$SESSION_INDEX_DB'); d.execute('PRAGMA user_version = 1'); d.commit()"
  python3 "$SCRIPT" build >"$FIX/m1.out" 2>"$FIX/m1.err" &
  python3 "$SCRIPT" build >"$FIX/m2.out" 2>"$FIX/m2.err" &
  wait
  if grep -l "database is locked" "$FIX"/m1.out "$FIX"/m1.err "$FIX"/m2.out "$FIX"/m2.err; then
    echo "migration race killed a build (see the file listed above)" >&2
    return 1
  fi
  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
}

@test "search never destroys an index it cannot read" {
  # A read that cannot be answered must SAY so, not repair by deletion. Sharing
  # get_db() with the write path meant a plain `search` against an older index
  # silently DROPped it: the caller asked a question and lost their data.
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics"
  python3 "$SCRIPT" build >/dev/null
  local before
  before="$(row_count)"
  [ "$before" -eq 1 ]
  python3 -c "import sqlite3; d=sqlite3.connect('$SESSION_INDEX_DB'); d.execute('PRAGMA user_version = 1'); d.commit()"

  run python3 "$SCRIPT" search "assorted"
  [ "$status" -ne 0 ]
  [[ "$output" == *"older version"* ]]
  # The index is intact and still at the version it had.
  [ "$(row_count)" -eq "$before" ]
  [ "$(python3 -c "import sqlite3; print(sqlite3.connect('$SESSION_INDEX_DB').execute('PRAGMA user_version').fetchone()[0])")" -eq 1 ]

  # And a build — the write path — still repairs it.
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
}

@test "search reports a missing index instead of creating one" {
  run python3 "$SCRIPT" search "anything"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no index yet"* ]]
  [ ! -e "$SESSION_INDEX_DB" ]
}

@test "provenance takes the first recorded cwd, not the last" {
  # A session that cd's mid-run records several. Measured over 118 real
  # transcripts, first and last are equally likely to still exist (114 each),
  # but where they differ the last has drifted somewhere transient — a job's
  # tmp dir, or plain $HOME — while the first still names the project.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 - "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for cwd in ("/home/me/the-real-project", "/home/me/the-real-project/tmp", "/home/me"):
        f.write(json.dumps({"type": "user", "cwd": cwd,
                            "message": {"content": "drifting cwd conversation text"}}) + "\n")
PY
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "drifting"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
hit = json.load(sys.stdin)[0]
assert hit["project"] == "/home/me/the-real-project", hit["project"]'
}

@test "the failure log is not world-readable" {
  # It names transcript paths. Created 0600 BEFORE the first write, because a
  # chmod after opening leaves a readable window.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  printf 'not json at all\n' >"$SESSION_INDEX_PROJECTS/-home-me-proj/bad.jsonl"
  chmod 000 "$SESSION_INDEX_PROJECTS/-home-me-proj/bad.jsonl"
  python3 "$SCRIPT" build >/dev/null 2>&1 || true
  chmod 644 "$SESSION_INDEX_PROJECTS/-home-me-proj/bad.jsonl"
  if [ -e "$SESSION_INDEX_DB.log" ]; then
    [ "$(stat -c '%a' "$SESSION_INDEX_DB.log")" = "600" ]
  else
    skip "no failure was recorded, so there is no log to check"
  fi
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
