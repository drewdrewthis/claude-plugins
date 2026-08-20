#!/usr/bin/env python3
"""Measure whether per-window rows fix issue #67's ranking inversion.

#67: a long, substantive assistant reply ranks BELOW a short user prompt that
merely mentions the term. Measured cause: FTS5's bm25 normalises a row's score
by that row's TOTAL token count across all columns, so per-column weights are a
no-op — 1.0/0.5/0.1 produced ordering identical to unweighted.

The fix under test (see the windowing rationale in session-index.py) is to stop
storing a whole session as one row. Windows of comparable size make the length
normaliser near-constant across rows, so term statistics decide the order.

This script builds the SAME fixture twice — once with the real indexer (windowed)
and once with a deliberately reconstructed one-row-per-session index — and prints
the bm25 scores and the resulting order for both. It asserts nothing: it reports,
so a human can decide whether windowing alone resolved the inversion or whether a
composite ORDER BY is still needed.

    python3 scripts/tests/measure-ranking.py

Exit status is 0 if the windowed index ranks the long substantive answer first,
1 if the inversion survives — so it can also be used as a check.
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "session-index.py")

TERM = "quokkatron"

# The two sessions #67 compares. `short-user` is the degenerate case that wins
# under whole-session rows: one sentence, so its bm25 denominator is tiny.
SHORT_USER = [
    ("user", "what about %s" % TERM),
]
PADDING = " ".join(
    "padding sentence number %d carrying no information at all" % i
    for i in range(60)
)
LONG_ASSISTANT = [
    ("user", "so what do you make of that plan overall"),
    ("assistant",
     "%s the %s cache is the bottleneck here, and %s is what we should shard "
     "first because everything else waits on it %s" % (PADDING, TERM, TERM, PADDING)),
]


def write_session(projects, project, sid, turns):
    d = os.path.join(projects, project)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".jsonl"), "w") as fh:
        for role, text in turns:
            fh.write(json.dumps(
                {"type": role, "cwd": "/home/me/proj",
                 "message": {"content": text}}) + "\n")


def build_fixture(root):
    projects = os.path.join(root, "projects")
    db = os.path.join(root, "sessions.db")
    write_session(projects, "-home-me-proj", "short-user", SHORT_USER)
    write_session(projects, "-home-me-proj", "long-assistant", LONG_ASSISTANT)
    env = dict(os.environ,
               SESSION_INDEX_PROJECTS=projects, SESSION_INDEX_DB=db)
    out = subprocess.run([sys.executable, SCRIPT, "build"],
                         capture_output=True, text=True, env=env)
    if out.returncode != 0:
        sys.exit("build failed: %s%s" % (out.stdout, out.stderr))
    return projects, db, env


def report_rows(db_path, label):
    """Every matching row with its bm25 score and its size, best first."""
    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row
    rows = db.execute("""
        SELECT session_id, line_offset, roles,
               length(user_text) as user_len,
               length(assistant_text) as asst_len,
               bm25(sessions_fts) as score
        FROM sessions_fts
        WHERE sessions_fts MATCH ?
        ORDER BY rank
    """, (TERM,)).fetchall()
    print("\n== %s ==" % label)
    print("%-16s %8s %-14s %6s %6s %10s"
          % ("session", "offset", "roles", "u_len", "a_len", "bm25"))
    for r in rows:
        print("%-16s %8s %-14s %6d %6d %10.4f"
              % (r["session_id"], r["line_offset"], r["roles"],
                 r["user_len"], r["asst_len"], r["score"]))
    # bm25() is more negative for a better match; `ORDER BY rank` uses it.
    return [r["session_id"] for r in rows]


def build_whole_session_index(db_path, out_path):
    """The OLD shape, reconstructed: one row per session, for contrast."""
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(out_path)
    dst.execute("CREATE VIRTUAL TABLE sessions_fts USING fts5("
                "file_path, session_id, project, user_text, assistant_text,"
                " line_offset UNINDEXED, roles UNINDEXED,"
                " tokenize='porter unicode61')")
    merged = {}
    for r in src.execute("SELECT file_path, session_id, project,"
                         " user_text, assistant_text FROM sessions_fts"):
        cur = merged.setdefault(r[1], [r[0], r[1], r[2], [], []])
        cur[3].append(r[3])
        cur[4].append(r[4])
    for cur in merged.values():
        dst.execute("INSERT INTO sessions_fts (file_path, session_id, project,"
                    " user_text, assistant_text, line_offset, roles)"
                    " VALUES (?,?,?,?,?,?,?)",
                    (cur[0], cur[1], cur[2], "\n".join(cur[3]),
                     "\n".join(cur[4]), 1, "whole-session"))
    dst.commit()


def main():
    root = tempfile.mkdtemp(prefix="recall-ranking-")
    try:
        projects, db, env = build_fixture(root)

        old_db = os.path.join(root, "whole.db")
        build_whole_session_index(db, old_db)
        old_order = report_rows(old_db, "BEFORE — one row per session (#67 shape)")
        new_order = report_rows(db, "AFTER — one row per window")

        print("\n== what `search` returns (windowed index) ==")
        out = subprocess.run(
            [sys.executable, SCRIPT, "search", TERM, "--limit", "10"],
            capture_output=True, text=True, env=env)
        hits = json.loads(out.stdout)
        for h in hits:
            print("  %-16s line_offset=%-5s roles=%-14s %s"
                  % (h["session_id"], h["line_offset"], h["roles"],
                     h["assistant_snippet"][:60].replace("\n", " ")))

        print("\n== verdict ==")
        print("before: %s" % (old_order,))
        print("after:  %s" % (new_order,))
        first = new_order[0] if new_order else None
        if first == "long-assistant":
            print("windowing RESOLVED the inversion: the substantive answer ranks first.")
            return 0
        print("inversion SURVIVES windowing (%r still first)." % (first,))
        print("next step: a composite ORDER BY over bm25 and `roles`.")
        return 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
