#!/usr/bin/env python3
"""
Session search index for Claude Code conversations.

Builds and queries a SQLite FTS5 index over all session JSONL files.
Supports incremental updates (only re-parses changed files).

Usage:
    session-index.py build                              # Build/update the index
    session-index.py search <query> [--limit N] [--project P]
    session-index.py context <path.jsonl> --tail N      # Last N turns
    session-index.py context <path.jsonl> --around L    # Turns around line L
    session-index.py context <path.jsonl> --match Q     # Turns around the best
                                                        # window for query Q

Search hits are WINDOWS, not whole sessions: each carries a `line_offset` that
`context --around` takes verbatim, so an excerpt is centred on the match rather
than on the end of the file.
"""

import argparse
import collections
import glob
import json
import os
import re
import sqlite3
import sys
import time
from urllib.request import pathname2url

# The FTS5 query translator is its own unit with its own table-driven tests; it
# was extracted after four consecutive fix rounds here each shipped a new
# silent-wrong-answer defect in it. Do not reimplement it inline.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fts5_query import Fts5QueryError, translate  # noqa: E402

# PLUGIN ADAPTATION: data-root defaults. Upstream this script lives inside the
# host codex and hardcodes `~/.claude`. Installed as a plugin it must not write
# into the plugin dir, and the host's config dir may be relocated, so the root
# resolves from CLAUDE_CONFIG_DIR (Claude Code's own var) with per-path escapes.
# The per-path vars are what let the test suite isolate onto a mktemp fixture
# and prove the "never writes into the plugin dir" property.
CONFIG_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
DB_PATH = os.path.expanduser(
    os.environ.get("SESSION_INDEX_DB") or os.path.join(CONFIG_DIR, "sessions.db")
)
PROJECTS_DIR = os.path.expanduser(
    os.environ.get("SESSION_INDEX_PROJECTS") or os.path.join(CONFIG_DIR, "projects")
)

# Prefixes that mark harness scaffolding rather than something a human said.
NOISE_PREFIXES = ("Base directory for this skill:", "<local-command")
MIN_TEXT_LEN = 10

# ── Windowing ────────────────────────────────────────────────────────────────
# The index stores one FTS5 row per WINDOW of a session, not one row per
# session. Two defects fall out of the one-row-per-session shape, and this
# fixes both:
#
#  1. A hit had no position. `search` could say "this session mentions X" but
#     not WHERE, so the reader could only take the tail of the file and hope.
#     A window row carries the line offset of its first message, so a hit
#     points at its own passage (`context --around <line_offset>`).
#
#  2. Ranking was dominated by length. FTS5's bm25 normalises a row's score by
#     that row's TOTAL token count across ALL columns, so per-column weights
#     are a no-op — measured: weights 1.0/0.5/0.1 produced identical ordering.
#     A whole session is thousands of tokens, and a session whose only content
#     is one short prompt therefore outranked a long, substantive answer every
#     time. Windows of COMPARABLE size make that normaliser near-constant
#     across rows, so the term statistics decide the order instead of the
#     document length. Each window is additionally tagged with its role
#     composition (`roles`), which is what a follow-up composite ORDER BY would
#     need if windowing alone proves insufficient — see
#     scripts/tests/measure-ranking.py, which reproduces the measurement.
#
# A single message longer than WINDOW_CHARS is split across several windows, on
# a whitespace boundary: otherwise one 4k-token assistant reply would remain a
# single outsized row and reintroduce exactly the normalisation skew above.
WINDOW_MESSAGES = 6
WINDOW_CHARS = 1200

# Bump whenever the table shape changes; a mismatch drops and rebuilds.
#
# ⚠ Bump it for a change in what gets EXTRACTED too, not only for a column. The
# incremental path keys on (mtime, size), and a finished session's transcript
# never changes again — so without a bump every already-indexed file is skipped
# forever and the new content is only ever captured for sessions yet to happen.
SCHEMA_VERSION = 4


def _schema_version(db):
    """0 for a pre-versioning index (or a fresh file), else the stamped version."""
    return db.execute("PRAGMA user_version").fetchone()[0]


class RecallIndexError(Exception):
    """A failure the caller should see as JSON, not as a traceback."""


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(1)


def open_for_read():
    """Open the index without creating, migrating, or otherwise mutating it.

    ⚠ The read paths must never share get_db(). They did, and a plain `search`
    against an index built by an older version silently DROPPED it — the caller
    asked a question and lost their data as a side effect. A read that cannot be
    answered says so; it does not repair anything.
    """
    if not os.path.exists(DB_PATH):
        raise RecallIndexError(
            "no index yet — run `session-index.py build` first"
        )
    # ⚠ Percent-encode the path. SQLite parses a URI filename, so a `#` in the
    # path terminates it and makes everything after — INCLUDING `?mode=ro` — a
    # fragment: the read-only flag was silently dropped and a DIFFERENT,
    # non-existent file was opened and CREATED, world-readable, by a read. The
    # os.path.exists() guard above and this open then disagreed about which
    # file they meant.
    uri = "file:%s?mode=ro" % pathname2url(os.path.abspath(DB_PATH))
    db = sqlite3.connect(uri, uri=True, timeout=60)
    db.row_factory = sqlite3.Row
    if _schema_version(db) != SCHEMA_VERSION:
        raise RecallIndexError(
            "the index was built by an older version of this script — "
            "run `session-index.py build` to rebuild it"
        )
    return db


def _ensure_wal(db):
    """Put the index in WAL mode, tolerating a concurrent opener.

    ⚠ Changing journal_mode needs an exclusive lock and returns SQLITE_BUSY
    IMMEDIATELY — the busy timeout is NOT consulted, the same trap as a schema
    change. Setting it unconditionally on every open is what made two builds
    race: the loser died with "database is locked" in ~4 runs of 5, and because
    the SessionEnd hook discards output, silently.

    journal_mode is persistent in the file, so reading it first makes the
    steady-state path a read that cannot contend. Only the genuine first set
    can lose, and there a retry-then-shrug is right: WAL is a performance
    property, not a correctness one, and whichever process wins sets it for
    everyone. Crucially this re-runs on EVERY open, so a lost first-set is
    retried on the next build and self-heals — without that, "gives up
    silently" would read as "WAL may never be set" and invite a hard error.
    """
    if (db.execute("PRAGMA journal_mode").fetchone()[0] or "").lower() == "wal":
        return
    for attempt in range(3):
        try:
            db.execute("PRAGMA journal_mode=WAL")
            return
        except sqlite3.OperationalError:
            time.sleep(0.05 * (attempt + 1))


def _migrate(db):
    """Discard an index whose shape predates this version, under a real lock.

    CREATE TABLE IF NOT EXISTS is a no-op against an existing table, so an index
    written by an older version keeps its old columns and every query then fails
    ("no such column: size") — permanently and invisibly, because the SessionEnd
    hook discards output. The index is a pure derived cache rebuildable from the
    transcripts, so the correct migration is to discard it rather than carry a
    ladder of ALTERs.

    ⚠ BEGIN IMMEDIATE is load-bearing, but not for the reason a DROP suggests.
    A DROP is an ordinary write and DOES consult the busy handler. The hazard
    is the read-then-write shape: this reads PRAGMA user_version and then
    writes, and under a DEFERRED transaction that read-lock -> write-lock
    UPGRADE returns SQLITE_BUSY without invoking the busy handler at all.
    Taking the write lock up front skips the upgrade. The re-read inside the
    lock then makes the loser a no-op rather than a second destructive drop.
    """
    if _schema_version(db) == SCHEMA_VERSION:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        if _schema_version(db) != SCHEMA_VERSION:
            db.execute("DROP TABLE IF EXISTS sessions")
            db.execute("DROP TABLE IF EXISTS sessions_fts")
            db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


# Ordinals of the two prose columns in sessions_fts, named once here because
# snippet() in search() addresses them positionally and has no way to check.
# line_offset and roles are appended AFTER them, and UNINDEXED, precisely so
# these two ordinals did not have to move.
# Kept immediately above the CREATE VIRTUAL TABLE in get_db() — the only other
# place the order is written down.
USER_TEXT_COL = 3
ASSISTANT_TEXT_COL = 4


def get_db():
    # PLUGIN ADAPTATION: a relocated CLAUDE_CONFIG_DIR may not exist yet.
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    fresh = not os.path.exists(DB_PATH)
    # A build holds one write transaction for the whole pass; the default 5s
    # busy timeout expires when two SessionEnd hooks fire at once, killing the
    # loser with "database is locked".
    if fresh:
        # The index aggregates every prompt typed on this host into one file —
        # a higher-value target than the transcripts it is built from. Created
        # 0600 BEFORE sqlite opens it: a chmod afterwards leaves a readable
        # window, which is the exact reasoning the failure log already applied.
        try:
            os.close(os.open(DB_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        except OSError:
            pass
    db = sqlite3.connect(DB_PATH, timeout=60)
    db.row_factory = sqlite3.Row
    _ensure_wal(db)
    _migrate(db)
    db.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            file_path TEXT PRIMARY KEY,
            session_id TEXT,
            project TEXT,
            cwd TEXT,
            mtime REAL,
            size INTEGER,
            message_count INTEGER,
            first_prompt TEXT,
            last_prompt TEXT
        )
    """)
    try:
        # ⚠ Column ORDER is load-bearing: search() addresses user_text and
        # assistant_text by index in snippet(), so reordering them silently
        # shows a hit the wrong side of the conversation. Move a column and
        # USER_TEXT_COL / ASSISTANT_TEXT_COL above must move with it.
        db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                file_path,
                session_id,
                project,
                user_text,
                assistant_text,
                line_offset UNINDEXED,
                roles UNINDEXED,
                tokenize='porter unicode61'
            )
        """)
    except sqlite3.OperationalError as exc:
        if "fts5" in str(exc).lower():
            raise RecallIndexError(
                "this python's sqlite3 was built without the FTS5 extension, "
                "which recall requires. See the plugin README for details."
            ) from exc
        raise
    return db


def iter_messages(jsonl_path, roles, start_line=1, stop_line=None):
    """Yield (line_no, role, text) for real turns, skipping harness noise.

    One filter policy for both the indexer and the reader — they drifted apart
    upstream, so a change landed in one and not the other.

    `line_no` is 1-based and counts EVERY line of the file, noise included, so
    it is a stable address into the transcript that survives any later change
    to the noise filter. It is what a search hit reports as `line_offset` and
    what `context --around` takes back.

    `start_line`/`stop_line` bound the read: the reader only ever wants a slice
    of a transcript, and streaming the whole of a multi-megabyte file to return
    ten turns is the read this replaces. `stop_line` is inclusive; the loop
    breaks at it rather than consuming the rest of the file.
    """
    # Transcripts routinely contain non-ASCII; under LC_ALL=C the locale default
    # raises UnicodeDecodeError and the whole file is silently dropped.
    with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            if line_no < start_line:
                continue
            if stop_line is not None and line_no > stop_line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            role = obj.get("type")
            if role not in roles:
                continue
            # A record can carry `"message": null`, and a text block can arrive
            # without its "text" key — both are real shapes, and both used to
            # raise out of the whole build.
            message = obj.get("message")
            content = message.get("content", "") if isinstance(message, dict) else ""
            if isinstance(content, list):
                text = " ".join(
                    c.get("text", "") for c in content
                    if isinstance(c, dict) and c.get("type") == "text"
                )
            elif isinstance(content, str):
                text = content
            else:
                # Non-string content would otherwise be indexed as a Python repr.
                continue
            text = text.strip()
            if len(text) < MIN_TEXT_LEN or text.startswith(NOISE_PREFIXES):
                continue
            yield line_no, role, text


def _chunk_text(text, size=WINDOW_CHARS):
    """Split an oversized message on whitespace into <=size pieces.

    Character-exact splitting would cut a word in half and hand FTS5 two
    tokens that appear nowhere in the transcript, so the break moves back to
    the last whitespace in the piece when there is one.
    """
    if len(text) <= size:
        return [text]
    pieces, rest = [], text
    while len(rest) > size:
        cut = rest.rfind(" ", 0, size)
        if cut <= 0:
            cut = size
        pieces.append(rest[:cut].strip())
        rest = rest[cut:].lstrip()
    if rest:
        pieces.append(rest)
    return [p for p in pieces if p]


def iter_windows(messages):
    """Group (line_no, role, text) triples into bounded, comparable windows.

    Yields a list of triples per window. A window closes at WINDOW_MESSAGES
    messages or WINDOW_CHARS characters, whichever comes first; a single
    message above WINDOW_CHARS is split by _chunk_text and its pieces carry
    the SAME line_no, because they all live on that one transcript line.
    """
    current, chars = [], 0
    for line_no, role, text in messages:
        for piece in _chunk_text(text):
            current.append((line_no, role, piece))
            chars += len(piece)
            if len(current) >= WINDOW_MESSAGES or chars >= WINDOW_CHARS:
                yield current
                current, chars = [], 0
    if current:
        yield current


def window_roles(window):
    """The role composition of a window: 'user', 'assistant' or 'user+assistant'.

    Carried on the row (UNINDEXED) so a ranking change can discriminate on who
    was speaking without re-reading the transcript.
    """
    roles = {role for _, role, _ in window}
    if roles == {"user"}:
        return "user"
    if roles == {"assistant"}:
        return "assistant"
    return "user+assistant"


def read_cwd(jsonl_path):
    """The working directory Claude Code recorded for this session, if present.

    Claude Code encodes a project path into its directory name by replacing every
    `/` with `-`, which is lossy — pre-existing hyphens are indistinguishable from
    separators, so the name cannot be decoded back to a path. It writes the real
    cwd into the transcript records instead; that is the only trustworthy source.

    A session records more than one cwd when it cd's mid-run; the FIRST is the
    provenance the reader wants. Measured over 118 real transcripts, first and
    last are equally likely to still exist on disk (114 each), but where they
    differ the last has drifted to somewhere transient — a job's tmp dir, or
    plain `/home/ubuntu` — while the first still names the project. Reading
    the first also lets the scan stop early instead of consuming the file.
    """
    with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("cwd"):
                return obj["cwd"]
    return None


def display_cwd(cwd):
    """A hit's real working directory, `~`-abbreviated, or None if none was recorded.

    ⚠ None rather than a fallback to the encoded directory name. One field
    carrying either a path or an identifier forced the caller to guess which by
    shape; `project` carries the identifier and this carries the path, so
    neither is ever mistaken for the other.
    """
    if not cwd:
        return None
    home = os.path.expanduser("~")
    if cwd == home or cwd.startswith(home + os.sep):
        return "~" + cwd[len(home):]
    return cwd


def build_index():
    db = get_db()
    files = [f for f in glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl"))]

    existing = {
        row["file_path"]: (row["mtime"], row["size"])
        for row in db.execute("SELECT file_path, mtime, size FROM sessions")
    }

    on_disk = set()
    indexed = skipped = failed = 0
    start = time.time()

    for f in files:
        # One unreadable file must not abort the pass — os.path.getmtime raising
        # here used to discard every session already parsed, and because nothing
        # was committed, every later build died at the same file forever.
        try:
            stat = os.stat(f)
            mtime, size = stat.st_mtime, stat.st_size
        except OSError:
            failed += 1
            # ⚠ Still count it as present. Omitting it from on_disk makes the
            # prune below DELETE a perfectly good row because of one transient
            # stat error — a read hiccup must not cost indexed data.
            on_disk.add(f)
            continue

        on_disk.add(f)
        # mtime alone misses a same-mtime rewrite (rsync -a, cp -p, a restore).
        if existing.get(f) == (mtime, size):
            skipped += 1
            continue

        session_id = os.path.basename(f)[: -len(".jsonl")]
        project = os.path.basename(os.path.dirname(f))
        try:
            # BOTH roles out of ONE pass, partitioned as they arrive — reading
            # the file is the expensive part of a build, so a second full pass
            # for the other role would roughly double it. read_cwd() below does
            # reopen the file, but it returns on the first record carrying a
            # cwd, which in a real transcript is line 1.
            prompts, replies, turns = [], [], []
            for line_no, role, text in iter_messages(f, {"user", "assistant"}):
                (replies if role == "assistant" else prompts).append(text)
                turns.append((line_no, role, text))
            windows = list(iter_windows(turns))
            cwd = read_cwd(f)
        except Exception:
            # Deliberately broad: the failures that actually occur are shape
            # errors in the record, not I/O. A narrower guard let one malformed
            # transcript abort the pass — which is the whole point of `failed`,
            # a typed skip surfaced in the result rather than swallowed.
            failed += 1
            continue

        # ⚠ Prompt-shaped fields stay USER-only. They are quoted back to the
        # human as what they asked; a reply folded in here would be presented
        # as something they said, and message_count would silently double.
        first_prompt = prompts[0][:200] if prompts else ""
        last_prompt = prompts[-1][:200] if prompts else ""

        # Keyed on file_path: a session id is unique only within a project dir,
        # so keying on it let one transcript silently overwrite another.
        db.execute("""
            INSERT INTO sessions
                (file_path, session_id, project, cwd, mtime, size,
                 message_count, first_prompt, last_prompt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                session_id=excluded.session_id, project=excluded.project,
                cwd=excluded.cwd, mtime=excluded.mtime, size=excluded.size,
                message_count=excluded.message_count,
                first_prompt=excluded.first_prompt, last_prompt=excluded.last_prompt
        """, (f, session_id, project, cwd, mtime, size,
              len(prompts), first_prompt, last_prompt))

        # One row per WINDOW. Re-inserting a file means deleting all of its
        # rows first — a shorter transcript would otherwise leave orphaned
        # windows behind, pointing at line offsets that no longer exist.
        db.execute("DELETE FROM sessions_fts WHERE file_path = ?", (f,))
        for window in windows:
            db.execute(
                "INSERT INTO sessions_fts"
                " (file_path, session_id, project, user_text, assistant_text,"
                "  line_offset, roles)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (f, session_id, project,
                 "\n".join(t for _, r, t in window if r != "assistant"),
                 "\n".join(t for _, r, t in window if r == "assistant"),
                 window[0][0], window_roles(window)))

        indexed += 1
        # Batched rather than per-file: committing every file made a cold build
        # 3.3x slower, and this runs in a SessionEnd hook. Batching still bounds
        # how much work an interrupted pass can lose.
        if indexed % 50 == 0:
            db.commit()

    # ⚠ Refuse to prune on an empty scan. glob() SWALLOWS I/O errors and
    # returns [], so an unreadable transcripts dir — an NFS/mutagen hiccup, a
    # permissions blip, a home not yet mounted — made every indexed path look
    # deleted and wiped the whole index, reporting {"removed": N, "failed": 0}
    # as success. The hook discards that output, so the first symptom would be
    # /recall answering "no transcripts indexed". The read path already refuses
    # to repair by deletion; the write path owes the same refusal.
    if not files and existing:
        raise RecallIndexError(
            "found no transcripts under %s but the index holds %d — refusing to "
            "prune. Check the directory is readable." % (PROJECTS_DIR, len(existing))
        )

    removed = 0
    for path in existing:
        if path not in on_disk:
            db.execute("DELETE FROM sessions WHERE file_path = ?", (path,))
            db.execute("DELETE FROM sessions_fts WHERE file_path = ?", (path,))
            removed += 1

    db.commit()
    total = db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]

    # The SessionEnd hook discards stdout AND stderr, so `failed` in the return
    # value is invisible on the only path that runs automatically — a skip
    # absorbed into a success count. Leave a durable breadcrumb instead.
    if failed:
        try:
            log_path = DB_PATH + ".log"
            # Same reasoning as the db itself: this names transcript paths, so
            # it must not be world-readable. Set before the first write, since
            # chmod after opening leaves a readable window.
            if not os.path.exists(log_path):
                os.close(os.open(log_path, os.O_CREAT | os.O_WRONLY, 0o600))
            with open(log_path, "a") as fh:
                fh.write(
                    f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
                    f"skipped {failed} unreadable transcript(s) of {len(files)}\n"
                )
        except OSError:
            pass

    return {
        "indexed": indexed,
        "skipped": skipped,
        "removed": removed,
        # Surfaced because the SessionEnd hook discards output: a transcript that
        # never indexes is otherwise invisible forever.
        "failed": failed,
        "total": total,
        "elapsed_seconds": round(time.time() - start, 2),
    }


def project_filter(value):
    """(encoded-dir-name, cwd) to scope a search by, from a name OR a path.

    Sessions live at <projects>/<munged-cwd>/<session>.jsonl, where Claude Code
    munges a cwd by replacing every `/` with `-`. That encoding is lossy — a
    real hyphen is indistinguishable from a separator — so this goes the
    lossless direction only: a PATH is munged forward to compare against the
    directory name, and is additionally compared against the cwd recorded
    inside the transcript. Anything without a separator is taken as the
    encoded directory name itself, which is what `search` reports as `project`.
    """
    value = os.path.expanduser(value)
    if os.sep in value:
        path = os.path.abspath(value)
        return path.replace(os.sep, "-"), path
    return value, None


def search(query, limit=10, project=None):
    db = open_for_read()
    total = db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    if total == 0:
        raise RecallIndexError("index is empty — no transcripts have been indexed yet")

    try:
        match = translate(query)
    except Fts5QueryError as exc:
        raise RecallIndexError(str(exc)) from exc
    if not match:
        raise RecallIndexError(f"query {query!r} has no searchable terms")

    scope, params = "", [match]
    if project:
        # Scoping happens in SQL rather than by filtering the result list:
        # filtering afterwards would silently return fewer than --limit rows
        # whenever the unscoped top-N happened to be from other projects.
        encoded, cwd = project_filter(project)
        scope = " AND (s.project = ? OR s.cwd = ?)"
        params += [encoded, cwd]
    params.append(limit)

    try:
        rows = db.execute(f"""
            SELECT
                s.session_id, s.project, s.cwd, s.file_path, s.mtime,
                s.message_count, s.first_prompt, s.last_prompt,
                f.line_offset as line_offset, f.roles as roles,
                snippet(sessions_fts, {USER_TEXT_COL}, '>>>', '<<<', '...', 24)
                    as snippet,
                snippet(sessions_fts, {ASSISTANT_TEXT_COL}, '>>>', '<<<', '...', 24)
                    as assistant_snippet
            FROM sessions_fts f
            JOIN sessions s ON s.file_path = f.file_path
            WHERE sessions_fts MATCH ?{scope}
            ORDER BY rank
            LIMIT ?
        """, params).fetchall()
    except sqlite3.OperationalError as exc:
        raise RecallIndexError(f"could not search for {query!r}: {exc}") from exc

    return [{
        "session_id": row["session_id"],
        # Two fields, two kinds of thing. `project` is ALWAYS the encoded
        # directory name — an identifier, never somewhere to cd — and `cwd` is
        # the real path or null. Merged into one field the caller could only
        # tell them apart by guessing at the shape of the string.
        "project": row["project"],
        "cwd": display_cwd(row["cwd"]),
        "file_path": row["file_path"],
        # The address of THIS hit inside the transcript. Hand it straight to
        # `context --around` — that is the whole point of per-window rows.
        "line_offset": int(row["line_offset"]),
        "roles": row["roles"],
        "mtime": row["mtime"],
        "message_count": row["message_count"],
        "first_prompt": row["first_prompt"],
        "last_prompt": row["last_prompt"],
        # Two snippets rather than one merged blob: which SIDE said it changes
        # how much a hit is worth, and only the matched side is highlighted.
        # A column with no match returns its opening text, unmarked.
        "snippet": row["snippet"],
        "assistant_snippet": row["assistant_snippet"],
    } for row in rows]


# How far back of a requested offset `context --around` starts reading. The
# point of --around is that a hit no longer costs a whole-file read; opening at
# line 1 would give that back. 400 lines is far more transcript than the ten or
# so turns a caller asks for, so the preceding half of the excerpt is never
# short in practice, and the cost is bounded regardless of file size.
AROUND_LOOKBACK_LINES = 400

# Words FTS5 reads as syntax rather than as something to look for. --match does
# its own scoring over the raw text, so it has to drop them itself.
_QUERY_OPERATORS = {"and", "or", "not", "near"}


def _resolve_transcript(jsonl_path):
    """The real path of an indexed transcript, or a JSON-able error."""
    real = os.path.realpath(jsonl_path)
    projects = os.path.realpath(PROJECTS_DIR)
    # The contract is "reads indexed transcripts"; without this the subcommand
    # will open any file the user can read.
    if os.path.commonpath([projects, real]) != projects:
        raise RecallIndexError(f"{jsonl_path} is not under the transcripts directory")
    if not os.path.isfile(real):
        raise RecallIndexError(f"{jsonl_path} is not a file")
    return real


def _present(line_no, role, text):
    """One turn as the reader sees it, or None if nothing survives the strip."""
    idx = text.find("<system-reminder>")
    # A message that BEGINS with a reminder has idx == 0, which is the
    # shape that actually occurs; `> 0` let all of them through.
    if idx >= 0:
        text = text[:idx].strip()
    if not text:
        return None
    return {"role": role, "line": line_no, "text": text[:400]}


def query_terms(query):
    """The searchable words of a query, lowercased, operators removed."""
    words = re.findall(r"\w+", (query or "").lower())
    return [w for w in words if w not in _QUERY_OPERATORS and len(w) > 1]


def _score_window(window, terms):
    """How well one window answers `terms`.

    Distinct terms present dominate, occurrences break ties — a window naming
    every word of the query once beats one that repeats a single word. The
    prefix fallback stands in for the porter stemmer the index uses and this
    pass does not have: `shard` must still find "sharding".
    """
    blob = " ".join(t for _, _, t in window).lower()
    distinct = occurrences = 0
    for term in terms:
        stem = term[:5] if len(term) > 5 else term
        n = blob.count(stem)
        if n:
            distinct += 1
            occurrences += n
    return (distinct, occurrences)


def best_window_offset(real, query):
    """The line offset of the window that best answers `query`, or None.

    Deliberately a re-scan of the transcript rather than an index lookup: it
    must work for a file whose index row is stale, and `context` is documented
    as reading transcripts, not the index. Memory stays bounded — only the
    best window seen so far is held.
    """
    terms = query_terms(query)
    if not terms:
        raise RecallIndexError(f"query {query!r} has no searchable terms")
    best_score, best_offset = (0, 0), None
    for window in iter_windows(iter_messages(real, {"user", "assistant"})):
        score = _score_window(window, terms)
        if score[0] and score > best_score:
            best_score, best_offset = score, window[0][0]
    return best_offset


def context(jsonl_path, tail=10, around=None, match=None):
    """Turns from one session: the tail, or an excerpt centred on a position.

    Three ways in, one shape out:
      --tail N          the last N turns (the original behaviour, unchanged)
      --around L        N turns centred on transcript line L, which is exactly
                        what a search hit reports as `line_offset`
      --match Q         the same, at the line the best-matching window starts

    --around exists because one FTS row per session could only ever say "the
    match is somewhere in here", so the reader took the END of the file and
    frequently quoted something unrelated to why the session matched.
    """
    real = _resolve_transcript(jsonl_path)
    if tail < 1:
        raise RecallIndexError("--tail must be at least 1")

    try:
        if match is not None:
            around = best_window_offset(real, match)
            if around is None:
                # Nothing matched. The tail is still a truthful answer to
                # "show me this session", and is what the caller had before.
                around = None
        if around is not None:
            return _context_around(real, around, tail)
        return _context_tail(real, tail)
    except OSError as exc:
        raise RecallIndexError(f"could not read {jsonl_path}: {exc}") from exc


def _context_tail(real, tail):
    """The last `tail` turns, holding only that many in memory.

    A deque rather than a full list sliced at the end: a long transcript is
    megabytes of prose and the caller wants ten turns of it.
    """
    keep = collections.deque(maxlen=tail)
    for line_no, role, text in iter_messages(real, {"user", "assistant"}):
        item = _present(line_no, role, text)
        if item:
            keep.append(item)
    return list(keep)


def _context_around(real, around, tail):
    """`tail` turns anchored on transcript line `around`.

    ⚠ Anchored, not centred on the midpoint. A `line_offset` is the FIRST line
    of the matching window, so the match itself lies at or AFTER it — a
    half-before/half-after split walks backwards past the hit and returns an
    excerpt that does not contain it. Measured: offset 79 with --tail 4 gave
    lines 77-80 while the matched text sat on line 81. So most of the budget
    goes forward, with a short lead-in for the question the passage answers.

    Bounded at BOTH ends: the read starts AROUND_LOOKBACK_LINES before the
    offset and stops as soon as the trailing budget is full, so the cost does
    not grow with the size of the transcript.
    """
    before = collections.deque(maxlen=min(max(tail // 5, 1), 3))
    after = []
    start = max(1, around - AROUND_LOOKBACK_LINES)
    for line_no, role, text in iter_messages(real, {"user", "assistant"}, start_line=start):
        item = _present(line_no, role, text)
        if not item:
            continue
        if line_no < around:
            before.append(item)
            continue
        after.append(item)
        # Stop as soon as enough follows the hit. `before` may be short (an
        # offset near the top of the file), and taking the shortfall here
        # keeps the excerpt `tail` long instead of silently truncating it.
        if len(after) >= tail - len(before):
            break
    return (list(before) + after)[:tail]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build", help="build or update the index")
    p_search = sub.add_parser("search", help="search indexed sessions")
    p_search.add_argument("query")
    p_search.add_argument("--limit", type=int, default=10)
    # --cwd is the same flag under the name the caller is more likely to have
    # in hand: a search hit reports both `project` (the encoded directory
    # name) and `cwd` (the real path), and either is accepted.
    p_search.add_argument(
        "--project", "--cwd", dest="project", default=None,
        help="scope to one project: its encoded directory name, or a path")
    p_context = sub.add_parser("context", help="messages from one session")
    p_context.add_argument("path")
    p_context.add_argument(
        "--tail", type=int, default=10,
        help="how many turns to return (the last N, unless --around/--match)")
    # Mutually exclusive: they name the same thing two ways, and passing both
    # would silently honour one.
    where = p_context.add_mutually_exclusive_group()
    where.add_argument(
        "--around", type=int, default=None,
        help="centre the excerpt on this transcript line (a hit's line_offset)")
    where.add_argument(
        "--match", default=None,
        help="centre the excerpt on the window that best matches this query")
    args = parser.parse_args()

    try:
        if args.command == "build":
            result = build_index()
        elif args.command == "search":
            result = search(args.query, args.limit, args.project)
        else:
            result = context(args.path, args.tail, args.around, args.match)
    except RecallIndexError as exc:
        fail(str(exc))
    except sqlite3.OperationalError as exc:
        fail(f"database error: {exc}")
    # ⚠ The skill is told EVERY failure arrives as {"error": ...}, and get_db's
    # makedirs plus the glob/stat path both raise OSError — an unwritable
    # CLAUDE_CONFIG_DIR handed it a traceback it has no way to parse.
    except OSError as exc:
        fail(f"could not access the index: {exc}")

    print(json.dumps(result, indent=2 if args.command != "build" else None))


if __name__ == "__main__":
    main()
