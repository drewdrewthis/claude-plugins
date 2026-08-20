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

# Octal permission bits of a file, e.g. 600. `stat -c` is GNU-only — macOS's
# stat rejects the flag outright, so the two mode assertions below erred rather
# than checked. Every other cross-platform probe in this suite already goes
# through python3; these do too.
file_mode() {
  python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])" "$1"
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

# write_exchange <project-dir> <session-id> <user-text> <assistant-text>
#
# One user turn and one independent assistant turn. write_session echoes every
# prompt back as "ack <prompt>", so it cannot express the case that matters
# here: something Claude said that the human never said. The assistant content
# is a block list, which is the shape real assistant records carry.
write_exchange() {
  local project="$1" sid="$2" user="$3" assistant="$4"
  mkdir -p "$SESSION_INDEX_PROJECTS/$project"
  python3 - "$SESSION_INDEX_PROJECTS/$project/$sid.jsonl" "$user" "$assistant" <<'PY'
import json, sys
path, user, assistant = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as fh:
    fh.write(json.dumps({"type": "user", "message": {"content": user}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "text", "text": assistant}]}}) + "\n")
PY
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
  [ "$(file_mode "$SESSION_INDEX_DB")" = "600" ]
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

@test "search finds a session by what Claude replied, not only by what was asked" {
  # The conclusion is usually in the answer, not the question: a human asks
  # "what should we do here" and never types the word the decision is named
  # after. Indexing prompts alone made those sessions unfindable by the only
  # term anyone would search for.
  write_exchange "-home-me-proj" "aaa" \
    "so what do you make of that plan" \
    "the bottleneck is the quokkatron cache, so we should shard it"
  write_session "-home-me-proj" "bbb" "" "unrelated chatter about breakfast options"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "quokkatron"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert r[0]["session_id"] == "aaa", r'
}

@test "a hit carries an assistant_snippet that highlights the matched reply" {
  # Two columns rather than one merged blob, so a hit can show WHICH side
  # matched. The user-side `snippet` keeps its existing name and meaning.
  write_exchange "-home-me-proj" "aaa" \
    "so what do you make of that plan" \
    "the bottleneck is the quokkatron cache, so we should shard it"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "quokkatron"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
hit = json.load(sys.stdin)[0]
assert "assistant_snippet" in hit, hit
assert ">>>quokkatron<<<" in hit["assistant_snippet"], hit["assistant_snippet"]
assert "snippet" in hit, hit
assert "quokkatron" not in hit["snippet"], hit["snippet"]
assert "make of that plan" in hit["snippet"], hit["snippet"]'
}

@test "result ORDER across hits is pinned, not incidental" {
  # SKILL.md tells the fork "results are ordered best-first — use the order",
  # and nothing asserted the order: every other multi-hit test here checks a
  # count or set membership, both of which survive any reshuffle.
  #
  # That matters because bm25 length-normalizes over the WHOLE row, not per
  # column. Adding assistant_text beside user_text therefore re-scored hits
  # that column never touched, and the top result changed with no test red.
  # This fixture puts one occurrence of the term in a SHORT user_text and one
  # in a LONG assistant_text and pins which wins, so the next column or weight
  # change has to move this line deliberately.
  local pad="" i
  for i in $(seq 1 60); do pad="$pad padding word number $i in the long reply"; done
  write_exchange "-home-me-proj" "short-user-hit" \
    "should we use zorblax here" \
    "that seems reasonable to me overall"
  write_exchange "-home-me-proj" "long-assistant-hit" \
    "what do you make of that plan" \
    "$pad the zorblax cache is the bottleneck $pad"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "zorblax"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
got = [h["session_id"] for h in json.load(sys.stdin)]
assert len(got) == 2, "both sessions must match before order means anything: %r" % (got,)
# Measured, unweighted bm25 over this schema: the short session whose HUMAN
# typed the term outranks the long reply that merely mentions it.
assert got == ["short-user-hit", "long-assistant-hit"], "result order changed: %r" % (got,)'
}

@test "a tool_use or tool_result block is not indexed, but its sibling prose is" {
  # iter_messages keeps only {"type": "text"} blocks. Tool traffic is machine
  # chatter — file contents, command output, whole diffs — and indexing it
  # would bury the prose the search exists to find. The distinctive strings
  # here live ONLY inside the tool blocks, so a hit proves the leak.
  mkdir -p "$SESSION_INDEX_PROJECTS/-home-me-proj"
  python3 - "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "user", "message": {
        "content": "please go and look at that file"}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "reading it now to see what it says"},
        {"type": "tool_use", "name": "Read",
         "input": {"file_path": "/x/thaumatropes.txt"}},
    ]}}) + "\n")
    fh.write(json.dumps({"type": "user", "message": {"content": [
        {"type": "tool_result",
         "content": "flibbertigibbet flibbertigibbet flibbertigibbet"},
    ]}}) + "\n")
PY
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "thaumatropes OR flibbertigibbet"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r == [], "tool traffic was indexed: %r" % (r,)'
  run python3 "$SCRIPT" search "reading"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
assert len(json.load(sys.stdin)) == 1, "the text block was dropped with the tool blocks"'
}

@test "first_prompt, last_prompt and prompt_count stay user-only" {
  # Prompt-shaped fields the skill reports back to the human. An assistant reply
  # leaking in would be presented as something the human typed, and the count
  # would silently double.
  write_session "-home-me-proj" "aaa" "" \
    "the first thing the human asked about" \
    "the second thing the human asked about"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "human"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
hit = json.load(sys.stdin)[0]
assert hit["first_prompt"] == "the first thing the human asked about", hit["first_prompt"]
assert hit["last_prompt"] == "the second thing the human asked about", hit["last_prompt"]
assert hit["prompt_count"] == 2, hit["prompt_count"]'
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

@test "an index stamped at the previous schema version is rebuilt, not skipped" {
  # The sharper sibling of the test above, and the one a version bump exists
  # for. Here the OLD index is well-formed and its row still matches the
  # transcript's (mtime, size), so the incremental path would skip the file —
  # forever, since the transcript of a finished session never changes again.
  # Every existing host would keep a user-only index and never know. Only the
  # SCHEMA_VERSION bump drops the table and forces the re-parse.
  write_exchange "-home-me-proj" "aaa" \
    "so what do you make of that plan" \
    "the bottleneck is the quokkatron cache, so we should shard it"
  python3 - "$SESSION_INDEX_DB" "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" <<'PY'
import os, sqlite3, sys
db_path, transcript = sys.argv[1], sys.argv[2]
prompt = "so what do you make of that plan"
st = os.stat(transcript)
db = sqlite3.connect(db_path)
db.execute("""CREATE TABLE sessions (
    file_path TEXT PRIMARY KEY, session_id TEXT, project TEXT, cwd TEXT,
    mtime REAL, size INTEGER, message_count INTEGER,
    first_prompt TEXT, last_prompt TEXT)""")
db.execute("CREATE VIRTUAL TABLE sessions_fts USING fts5("
           "file_path, session_id, project, user_text, tokenize='porter unicode61')")
db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?)",
           (transcript, "aaa", "-home-me-proj", None,
            st.st_mtime, st.st_size, 1, prompt, prompt))
db.execute("INSERT INTO sessions_fts (file_path, session_id, project, user_text)"
           " VALUES (?,?,?,?)", (transcript, "aaa", "-home-me-proj", prompt))
db.execute("PRAGMA user_version = 2")
db.commit()
PY
  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d["indexed"] == 1, "an unchanged transcript was skipped instead of rebuilt: %r" % (d,)
assert d["skipped"] == 0, d
assert d["total"] == 1, d'
  run python3 "$SCRIPT" search "quokkatron"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
assert len(json.load(sys.stdin)) == 1, "assistant text stayed unindexed after the bump"'
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

@test "a build tolerates a held lock while setting journal_mode" {
  # DETERMINISTIC replacement for a race that could not be lost: the old
  # version of this detected the loss of _ensure_wal's guard 0 times in 13.
  # Same lesson as the migration test — a race you cannot lose is not a test.
  #
  # Setting journal_mode needs an EXCLUSIVE lock and returns SQLITE_BUSY
  # immediately, without consulting the busy timeout. So start from a non-WAL
  # db, hold a write lock, and prove the build survives it.
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics"
  python3 -c "
import sqlite3
d = sqlite3.connect('$SESSION_INDEX_DB')
d.execute('PRAGMA journal_mode=DELETE')
d.execute('CREATE TABLE IF NOT EXISTS placeholder (x)')
d.commit()"

  python3 -c "
import sqlite3, time
d = sqlite3.connect('$SESSION_INDEX_DB', timeout=60)
d.execute('BEGIN IMMEDIATE')
time.sleep(1.5)
d.execute('COMMIT')" &
  local holder=$!
  sleep 0.3

  run python3 "$SCRIPT" build
  wait "$holder"
  [ "$status" -eq 0 ] || { echo "build died setting journal_mode: $output" >&2; return 1; }
  [[ "$output" != *"database is locked"* ]]
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

@test "a migration waits for a held write lock instead of dying on it" {
  # DETERMINISTIC, because the obvious version of this test is vacuous: racing
  # two builds at a bumped version never once went red across 35 trials with
  # the lock fully removed — the fixture is far too fast for the two processes
  # to collide. A race you cannot lose is not a test.
  #
  # So hold the write lock deliberately and prove the migration WAITS for it.
  # The mechanism being pinned: _migrate reads PRAGMA user_version and then
  # writes, and under a DEFERRED transaction that read-lock -> write-lock
  # upgrade returns SQLITE_BUSY *without consulting the busy handler at all*.
  # BEGIN IMMEDIATE takes the write lock up front and therefore honours the
  # timeout. Remove it and this fails in well under a second, every time.
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics"
  python3 "$SCRIPT" build >/dev/null
  python3 -c "import sqlite3; d=sqlite3.connect('$SESSION_INDEX_DB'); d.execute('PRAGMA user_version = 1'); d.commit()"

  # Hold the write lock for ~1.5s, then release. Backgrounded, not raced.
  python3 -c "
import sqlite3, time
d = sqlite3.connect('$SESSION_INDEX_DB', timeout=60)
d.execute('BEGIN IMMEDIATE')
time.sleep(1.5)
d.execute('COMMIT')" &
  local holder=$!
  sleep 0.3   # let the holder acquire before the build attempts its migration

  run python3 "$SCRIPT" build
  wait "$holder"
  [ "$status" -eq 0 ] || { echo "migration died on a held lock: $output" >&2; return 1; }
  [[ "$output" != *"database is locked"* ]]

  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
}

@test "a read hiccup never costs indexed data" {
  # glob() SWALLOWS I/O errors and returns [], so an unreadable transcripts dir
  # made every indexed path look deleted: the prune wiped the whole index and
  # reported {"removed": N, "failed": 0} — success. The SessionEnd hook
  # discards that, so the first symptom is /recall saying "no transcripts".
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics"
  python3 "$SCRIPT" build >/dev/null
  [ "$(row_count)" -eq 1 ]

  chmod 000 "$SESSION_INDEX_PROJECTS/-home-me-proj"
  run python3 "$SCRIPT" build
  chmod 755 "$SESSION_INDEX_PROJECTS/-home-me-proj"
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root — chmod 000 does not deny reads, so the hiccup cannot be simulated"
  fi
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to prune"* ]]
  # The whole point: the data is still there.
  [ "$(row_count)" -eq 1 ]
  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
}

@test "one transcript that stops being statable does not prune its row" {
  # Narrower sibling of the hiccup above, and the one the prune guard does NOT
  # cover: here glob() still returns files, so the empty-scan refusal never
  # fires. A single stat failure counted `failed` but ALSO left the path out of
  # on_disk, so the prune deleted a good row for one transient error.
  write_session "-home-me-proj" "aaa" "" "the first conversation about assorted topics"
  write_session "-home-me-proj" "bbb" "" "the second conversation about assorted topics"
  python3 "$SCRIPT" build >/dev/null
  [ "$(row_count)" -eq 2 ]

  # A dangling symlink: glob lists it, os.stat raises on it.
  rm "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl"
  ln -s "$FIX/does-not-exist.jsonl" "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl"

  run python3 "$SCRIPT" build
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["failed"] == 1, r
assert r["removed"] == 0, "a stat failure pruned a good row: %r" % (r,)
assert r["total"] == 2, r'
  [ "$(row_count)" -eq 2 ]
}

@test "a path containing '#' is opened as itself, not parsed as a URI" {
  # SQLite parses a URI filename, so a '#' terminates it and makes everything
  # after — INCLUDING '?mode=ro' — a fragment. The read-only flag was dropped
  # and a DIFFERENT, non-existent file was opened and CREATED world-readable
  # BY A READ, while the exists() guard above it checked the real path.
  export SESSION_INDEX_DB="$FIX/ses#1.db"
  write_session "-home-me-proj" "aaa" "" "a conversation about assorted topics"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "assorted"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==1'
  # No stray file conjured from the truncated path.
  [ ! -e "$FIX/ses" ]
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
assert hit["cwd"] == "/home/me/the-real-project", hit["cwd"]'
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
    [ "$(file_mode "$SESSION_INDEX_DB.log")" = "600" ]
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

@test "an unwritable config dir reports JSON, not a traceback" {
  # SKILL.md tells the fork EVERY failure arrives as {"error": ...} and to
  # report it verbatim. get_db's makedirs raises OSError, which main() did not
  # catch — so a relocated, unwritable CLAUDE_CONFIG_DIR handed the skill a
  # traceback it has no way to parse.
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root — chmod 000 does not deny writes, so the failure cannot be simulated"
  fi
  local locked="$FIX/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  export CLAUDE_CONFIG_DIR="$locked/config"
  unset SESSION_INDEX_DB SESSION_INDEX_PROJECTS

  # Streams kept APART on purpose. fail() print()s to STDOUT, so a check that
  # looked for the JSON on stderr — or for the traceback on stdout — would pass
  # whether or not the handler exists. Same trap the concurrency test hit.
  local rc=0
  python3 "$SCRIPT" build >"$FIX/out" 2>"$FIX/err" || rc=$?
  chmod 755 "$locked"

  [ "$rc" -eq 1 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "error" in d, d' "$FIX/out"
  [[ "$(cat "$FIX/err")" != *Traceback* ]]
}

@test "cwd carries the real path while project stays the encoded dir name" {
  # The decisive case: the dir name encodes `/` as `-` without escaping, so
  # `-home-me-my-project` is ambiguous. The recorded cwd is the only truth, and
  # it travels in its OWN field — one field carrying either a path or an
  # identifier left the caller guessing which by the shape of the string.
  write_session "-home-me-my-project" "aaa" "/home/me/my-project" "conversation inside a hyphenated repo"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "hyphenated"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["cwd"] == "/home/me/my-project", r[0]["cwd"]
assert r[0]["project"] == "-home-me-my-project", r[0]["project"]'
}

@test "a hidden directory in the cwd survives intact" {
  write_session "-home-me--claude" "aaa" "/home/me/.claude" "conversation inside a dotted config dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "dotted"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["cwd"] == "/home/me/.claude", r[0]["cwd"]'
}

@test "a cwd under the real home renders as a ~ path" {
  write_session "-fixture-proj" "aaa" "$HOME/recall-fixture" "conversation beneath the real home dir"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "beneath"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["cwd"] == "~/recall-fixture", r[0]["cwd"]'
}

@test "with no recorded cwd, cwd is null and project is still the encoded name" {
  # Null, not a fallback: the encoded name is an identifier, and the caller must
  # never be handed it in the field it reads as a path — "/home/me/my/project"
  # is what decoding it would invent, and that directory does not exist.
  write_session "-home-me-my-project" "aaa" "" "conversation with no cwd recorded anywhere"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "fabricated OR conversation"
  echo "$output" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r[0]["cwd"] is None, r[0]["cwd"]
assert r[0]["project"] == "-home-me-my-project", r[0]["project"]'
}

# ─── per-window rows, positioned hits (#66) ─────────────────────────────────

# write_long_session <project-dir> <session-id> <needle>
#
# A session long enough that the needle CANNOT be reached by taking the tail:
# 40 filler exchanges, the needle in the middle, 40 more after it. This is the
# shape the whole-session-per-row index got wrong — the match was real, the
# excerpt shown was the end of the file.
write_long_session() {
  local project="$1" sid="$2" needle="$3"
  mkdir -p "$SESSION_INDEX_PROJECTS/$project"
  python3 - "$SESSION_INDEX_PROJECTS/$project/$sid.jsonl" "$needle" <<'PY'
import json, sys
path, needle = sys.argv[1], sys.argv[2]
def rec(role, text):
    return json.dumps({"type": role, "message": {"content": text}}) + "\n"
with open(path, "w") as fh:
    for i in range(40):
        fh.write(rec("user", "filler question number %d about ordinary matters" % i))
        fh.write(rec("assistant", "filler answer number %d about ordinary matters" % i))
    fh.write(rec("user", "and what about the %s question" % needle))
    fh.write(rec("assistant", "the %s is settled: we cache it and move on" % needle))
    for i in range(40):
        fh.write(rec("user", "trailing question number %d about other matters" % i))
        fh.write(rec("assistant", "trailing answer number %d about other matters" % i))
PY
}

@test "one session produces several FTS windows, not one row" {
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  python3 "$SCRIPT" build >/dev/null
  run python3 -c "
import sqlite3
db = sqlite3.connect('$SESSION_INDEX_DB')
print(db.execute('select count(*) from sessions_fts').fetchone()[0])
print(db.execute('select count(*) from sessions').fetchone()[0])"
  [ "$status" -eq 0 ]
  local windows sessions
  windows="$(echo "$output" | sed -n 1p)"
  sessions="$(echo "$output" | sed -n 2p)"
  [ "$sessions" -eq 1 ]
  [ "$windows" -gt 1 ] || { echo "the session was stored as $windows row(s)"; return 1; }
}

@test "a search hit carries the line offset of the window that matched" {
  # Without this the reader knows a session matched but not WHERE, which is
  # why it fell back to the tail of the file.
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "quokkatron"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
hits = json.load(sys.stdin)
assert hits, "the needle window did not match at all"
off = hits[0]["line_offset"]
assert isinstance(off, int), repr(off)
# The needle sits after 40 exchanges (80 lines) and before the trailing 80.
assert 75 <= off <= 90, "offset %r does not point at the needle window" % (off,)
assert hits[0]["roles"] in ("user", "assistant", "user+assistant"), hits[0]["roles"]'
}

@test "every window row of a rebuilt transcript is replaced, not appended" {
  # A shorter rewrite must not leave windows behind pointing at line offsets
  # that no longer exist.
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  python3 "$SCRIPT" build >/dev/null
  write_session "-home-me-proj" "aaa" "" "a much shorter conversation about quokkatron"
  python3 "$SCRIPT" build >/dev/null
  run python3 -c "
import sqlite3
db = sqlite3.connect('$SESSION_INDEX_DB')
print(max(r[0] for r in db.execute('select line_offset from sessions_fts')))"
  [ "$status" -eq 0 ]
  [ "$output" -le 4 ] || { echo "stale windows survived: max offset $output"; return 1; }
}

@test "context --around centres the excerpt on the offset" {
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  python3 "$SCRIPT" build >/dev/null
  local offset
  offset="$(python3 "$SCRIPT" search "quokkatron" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["line_offset"])')"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --around "$offset" --tail 6
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert len(m) == 6, m
assert any("quokkatron" in x["text"] for x in m), [x["text"] for x in m]
assert any("filler" in x["text"] for x in m), "nothing BEFORE the hit was included"
assert not any("trailing question number 39" in x["text"] for x in m), "this is the tail, not the excerpt"'
}

@test "context --around near the top of a transcript still returns tail turns" {
  # `before` is short here, and the shortfall must be taken from after rather
  # than silently returning half an excerpt.
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --around 1 --tail 6
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert len(m) == 6, m
assert m[0]["line"] == 1, m[0]'
}

@test "context --match finds the passage in a long session" {
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --match "quokkatron" --tail 6
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert any("quokkatron" in x["text"] for x in m), [x["text"] for x in m]'
}

@test "context --match with no hit falls back to the tail rather than erroring" {
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --match "zzzznothinghere" --tail 3
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert len(m) == 3, m
assert "trailing" in m[-1]["text"], m[-1]'
}

@test "context --tail still returns the end of the session" {
  # Backward compatibility: the flag the skill used before --around existed.
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --tail 2
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert len(m) == 2, m
assert "trailing answer number 39" in m[-1]["text"], m[-1]'
}

@test "context rejects --around together with --match" {
  write_long_session "-home-me-proj" "aaa" "quokkatron"
  run python3 "$SCRIPT" context "$SESSION_INDEX_PROJECTS/-home-me-proj/aaa.jsonl" --around 5 --match "quokkatron"
  [ "$status" -ne 0 ]
}

# ─── project scoping (#69) ──────────────────────────────────────────────────

@test "search --project scopes to one project by encoded directory name" {
  # `--project=<value>`, not `--project <value>`: an encoded directory name
  # begins with a hyphen, which argparse would otherwise read as a flag.
  write_session "-home-me-alpha" "aaa" "/home/me/alpha" "the tokenizer decision we made here"
  write_session "-home-me-beta"  "bbb" "/home/me/beta"  "the tokenizer decision we made here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer"
  echo "$output" | python3 -c 'import json,sys; assert len(json.load(sys.stdin))==2, "fixture is wrong: both must match unscoped"'
  run python3 "$SCRIPT" search "tokenizer" --project=-home-me-alpha
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert r[0]["project"] == "-home-me-alpha", r[0]["project"]'
}

@test "search --project accepts a real path as well as the encoded name" {
  write_session "-home-me-alpha" "aaa" "/home/me/alpha" "the tokenizer decision we made here"
  write_session "-home-me-beta"  "bbb" "/home/me/beta"  "the tokenizer decision we made here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --project "/home/me/beta"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert len(r) == 1, r
assert r[0]["session_id"] == "bbb", r[0]'
}

@test "--cwd is accepted as the name for the same scoping flag" {
  write_session "-home-me-alpha" "aaa" "/home/me/alpha" "the tokenizer decision we made here"
  write_session "-home-me-beta"  "bbb" "/home/me/beta"  "the tokenizer decision we made here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --cwd "/home/me/alpha"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert len(r) == 1 and r[0]["session_id"] == "aaa", r'
}

@test "a project scope that matches nothing returns an empty list, not an error" {
  write_session "-home-me-alpha" "aaa" "/home/me/alpha" "the tokenizer decision we made here"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --project=-home-me-nowhere
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin) == []'
}

@test "scoping applies before --limit, not after" {
  # Filtering the result list afterwards returns fewer rows than asked for
  # whenever the unscoped top-N came from elsewhere.
  local i
  for i in $(seq 1 5); do
    write_session "-home-me-beta" "b$i" "/home/me/beta" "tokenizer discussion number $i in beta"
  done
  write_session "-home-me-alpha" "a1" "/home/me/alpha" "tokenizer discussion number one in alpha"
  write_session "-home-me-alpha" "a2" "/home/me/alpha" "tokenizer discussion number two in alpha"
  python3 "$SCRIPT" build >/dev/null
  run python3 "$SCRIPT" search "tokenizer" --project=-home-me-alpha --limit 2
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert len(r) == 2, "scope was applied after the limit: %r" % (r,)
assert all(h["project"] == "-home-me-alpha" for h in r), r'
}
