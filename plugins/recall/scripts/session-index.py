#!/usr/bin/env python3
"""
Session search index for Claude Code conversations.

Builds and queries a SQLite FTS5 index over all session JSONL files.
Supports incremental updates (only re-parses changed files).

Usage:
    session-index.py build                            # Build/update the index
    session-index.py search <query> [--limit N]       # Search sessions, output JSON
    session-index.py context <path.jsonl> [--tail N]  # Recent messages from a session
"""

import argparse
import glob
import json
import os
import re
import sqlite3
import sys
import time

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

# Bump whenever the table shape changes; a mismatch drops and rebuilds.
SCHEMA_VERSION = 2

# A bare trailing-* prefix term, e.g. `kuber*` — passed through unquoted.
PREFIX_TERM = re.compile(r"^\w+\*$")


def _schema_version(db):
    """0 for a pre-versioning index (or a fresh file), else the stamped version."""
    return db.execute("PRAGMA user_version").fetchone()[0]


class IndexError_(Exception):
    """A failure the caller should see as JSON, not as a traceback."""


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(1)


def get_db():
    # PLUGIN ADAPTATION: a relocated CLAUDE_CONFIG_DIR may not exist yet.
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    fresh = not os.path.exists(DB_PATH)
    # A build holds one write transaction for the whole pass; the default 5s
    # busy timeout expires when two SessionEnd hooks fire at once, killing the
    # loser with "database is locked".
    db = sqlite3.connect(DB_PATH, timeout=60)
    if fresh:
        # The index aggregates every prompt typed on this host into one file —
        # a higher-value target than the transcripts it is built from.
        try:
            os.chmod(DB_PATH, 0o600)
        except OSError:
            pass
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    # CREATE TABLE IF NOT EXISTS is a no-op against an existing table, so an
    # index written by an older version keeps its old columns and every query
    # then fails ("no such column: size") — permanently, and invisibly, because
    # the SessionEnd hook discards output. The index is a pure derived cache
    # rebuildable from the transcripts, so the correct migration is to discard
    # it rather than carry a ladder of ALTERs.
    if _schema_version(db) != SCHEMA_VERSION:
        db.execute("DROP TABLE IF EXISTS sessions")
        db.execute("DROP TABLE IF EXISTS sessions_fts")
        db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
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
        db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                file_path,
                session_id,
                project,
                user_text,
                tokenize='porter unicode61'
            )
        """)
    except sqlite3.OperationalError as exc:
        if "fts5" in str(exc).lower():
            raise IndexError_(
                "this python's sqlite3 was built without the FTS5 extension, "
                "which recall requires. See the plugin README for details."
            ) from exc
        raise
    return db


def iter_messages(jsonl_path, roles):
    """Yield (role, text) for real conversation turns, skipping harness noise.

    One filter policy for both the indexer and the reader — they drifted apart
    upstream, so a change landed in one and not the other.
    """
    # Transcripts routinely contain non-ASCII; under LC_ALL=C the locale default
    # raises UnicodeDecodeError and the whole file is silently dropped.
    with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
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
            yield role, text


def read_cwd(jsonl_path):
    """The working directory Claude Code recorded for this session, if present.

    Claude Code encodes a project path into its directory name by replacing every
    `/` with `-`, which is lossy — pre-existing hyphens are indistinguishable from
    separators, so the name cannot be decoded back to a path. It writes the real
    cwd into the transcript records instead; that is the only trustworthy source.

    A resumed session records more than one cwd; the LAST is where the work
    actually happened. Scanning the whole file also catches the transcripts
    whose first record carries no cwd at all.
    """
    found = None
    with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("cwd"):
                found = obj["cwd"]
    return found


def display_path(cwd, project):
    """What to show as a hit's provenance: the real cwd, else the raw dir name."""
    if not cwd:
        # Never fabricate a path from the encoded name — return it verbatim so a
        # reader can tell it is an identifier, not somewhere they can cd to.
        return project
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
            continue

        on_disk.add(f)
        # mtime alone misses a same-mtime rewrite (rsync -a, cp -p, a restore).
        if existing.get(f) == (mtime, size):
            skipped += 1
            continue

        session_id = os.path.basename(f)[: -len(".jsonl")]
        project = os.path.basename(os.path.dirname(f))
        try:
            messages = [text for _, text in iter_messages(f, {"user"})]
            cwd = read_cwd(f)
        except Exception:
            # Deliberately broad: the failures that actually occur are shape
            # errors in the record, not I/O. A narrower guard let one malformed
            # transcript abort the pass — which is the whole point of `failed`,
            # a typed skip surfaced in the result rather than swallowed.
            failed += 1
            continue

        combined = "\n".join(messages)
        first_prompt = messages[0][:200] if messages else ""
        last_prompt = messages[-1][:200] if messages else ""

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
              len(messages), first_prompt, last_prompt))

        db.execute("DELETE FROM sessions_fts WHERE file_path = ?", (f,))
        db.execute(
            "INSERT INTO sessions_fts (file_path, session_id, project, user_text)"
            " VALUES (?, ?, ?, ?)",
            (f, session_id, project, combined))

        indexed += 1
        # Batched rather than per-file: committing every file made a cold build
        # 3.3x slower, and this runs in a SessionEnd hook. Batching still bounds
        # how much work an interrupted pass can lose.
        if indexed % 50 == 0:
            db.commit()

    removed = 0
    for path in existing:
        if path not in on_disk:
            db.execute("DELETE FROM sessions WHERE file_path = ?", (path,))
            db.execute("DELETE FROM sessions_fts WHERE file_path = ?", (path,))
            removed += 1

    db.commit()
    total = db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
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


def build_match_query(query):
    """Turn a user's words into a valid FTS5 MATCH expression.

    FTS5 reads its input as a query language, so ordinary prose detonates it: a
    hyphen reads as a column filter (`rate-limiter` -> "no such column: limiter"),
    an apostrophe as an unterminated string. Quoting each bare term makes it a
    literal while leaving the boolean operators the skill relies on intact.

    Enumerated over every FTS5 operator, not only the ones seen to break:
    AND / OR / NOT (binary, kept), NEAR (needs NEAR(a b) grouping the caller
    cannot express, so quoted as a literal), `*` prefix (preserved — it is the
    cheapest recall lever the skill has), and `"` / `(` / `:` / `^`, which are
    neutralised by quoting.
    """
    binary_ops = {"AND", "OR", "NOT"}
    out = []
    for token in query.split():
        if token in binary_ops:
            # Collapse a repeated operator ("a OR OR b") rather than emit a
            # syntax error.
            if out and out[-1] in binary_ops:
                continue
            out.append(token)
        elif PREFIX_TERM.match(token):
            out.append(token)
        else:
            out.append('"' + token.replace('"', '""') + '"')

    # A leading NOT cannot be honoured: FTS5's NOT is binary, so dropping it
    # silently returns the exact complement of what was asked for.
    if out and out[0] == "NOT":
        raise IndexError_(
            "a query cannot begin with NOT — FTS5 excludes with 'a NOT b'"
        )
    # A union built programmatically can start or end on a dangling operator,
    # which is a syntax error rather than a no-op.
    while out and out[0] in binary_ops:
        out.pop(0)
    while out and out[-1] in binary_ops:
        out.pop()
    return " ".join(out)


def search(query, limit=10):
    db = get_db()
    total = db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    if total == 0:
        raise IndexError_("index is empty — no transcripts have been indexed yet")

    match = build_match_query(query)
    if not match:
        raise IndexError_(f"query {query!r} has no searchable terms")

    try:
        rows = db.execute("""
            SELECT
                s.session_id, s.project, s.cwd, s.file_path, s.mtime,
                s.message_count, s.first_prompt, s.last_prompt,
                snippet(sessions_fts, 3, '>>>', '<<<', '...', 24) as snippet
            FROM sessions_fts f
            JOIN sessions s ON s.file_path = f.file_path
            WHERE sessions_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        """, (match, limit)).fetchall()
    except sqlite3.OperationalError as exc:
        raise IndexError_(f"could not search for {query!r}: {exc}") from exc

    return [{
        "session_id": row["session_id"],
        "project": display_path(row["cwd"], row["project"]),
        "file_path": row["file_path"],
        "mtime": row["mtime"],
        "message_count": row["message_count"],
        "first_prompt": row["first_prompt"],
        "last_prompt": row["last_prompt"],
        "snippet": row["snippet"],
    } for row in rows]


def context(jsonl_path, tail=10):
    """Recent user/assistant turns from one session."""
    real = os.path.realpath(jsonl_path)
    projects = os.path.realpath(PROJECTS_DIR)
    # The contract is "reads indexed transcripts"; without this the subcommand
    # will open any file the user can read.
    if os.path.commonpath([projects, real]) != projects:
        raise IndexError_(f"{jsonl_path} is not under the transcripts directory")
    if not os.path.isfile(real):
        raise IndexError_(f"{jsonl_path} is not a file")

    messages = []
    try:
        for role, text in iter_messages(real, {"user", "assistant"}):
            idx = text.find("<system-reminder>")
            # A message that BEGINS with a reminder has idx == 0, which is the
            # shape that actually occurs; `> 0` let all of them through.
            if idx >= 0:
                text = text[:idx].strip()
            if not text:
                continue
            messages.append({"role": role, "text": text[:400]})
    except OSError as exc:
        raise IndexError_(f"could not read {jsonl_path}: {exc}") from exc

    return messages[-tail:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build", help="build or update the index")
    p_search = sub.add_parser("search", help="search indexed sessions")
    p_search.add_argument("query")
    p_search.add_argument("--limit", type=int, default=10)
    p_context = sub.add_parser("context", help="recent messages from one session")
    p_context.add_argument("path")
    p_context.add_argument("--tail", type=int, default=10)
    args = parser.parse_args()

    try:
        if args.command == "build":
            result = build_index()
        elif args.command == "search":
            result = search(args.query, args.limit)
        else:
            result = context(args.path, args.tail)
    except IndexError_ as exc:
        fail(str(exc))
    except sqlite3.OperationalError as exc:
        fail(f"database error: {exc}")

    print(json.dumps(result, indent=2 if args.command != "build" else None))


if __name__ == "__main__":
    main()
