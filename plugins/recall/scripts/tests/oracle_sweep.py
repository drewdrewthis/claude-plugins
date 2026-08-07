#!/usr/bin/env python3
"""Assert translate()'s drop-oracle agrees with FTS5's tokenizer, per character.

THE ROUND-SEVEN LESSON, as a property rather than a row.

Defects 6 and 7 were both "a token that renders to an EMPTY FTS5 phrase, which
ANDs to nothing and silently empties the result". Defect 6 was fixed by dropping
such tokens; defect 7 was that the regex deciding WHICH tokens to drop (`\\w`)
was a WIDER oracle than the tokenizer it approximated — `_` is a word character
to Python and a separator to unicode61 — so the fix's own guard leaked the very
defect it was written to stop.

Patching the regex again would have been the fifth symptom-level patch. This
pins the invariant instead: for every character, translate() drops it exactly
when FTS5 would tokenize it to nothing. A future divergence — a changed
tokenizer, an edited regex — fails here by construction, before it can become
another wrong answer.
"""

import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from fts5_query import Fts5QueryError, translate  # noqa: E402

# Every ASCII printable, plus the non-ASCII classes a real transcript carries:
# accented Latin, Greek, Cyrillic, CJK, Hangul, non-Latin digits, superscripts,
# dashes, combining marks, emoji — and the connector punctuation behind defect 7.
SWEEP = [chr(c) for c in range(0x20, 0x7F)] + list(
    "áéîõüßçñ" "αβγδ" "абвг" "日本語中文" "한글" "٤٥٦" "½²³" "—–…" "ّ́" "🚀🔥" "_＿﹍"
)


def main():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE VIRTUAL TABLE t USING fts5(b, tokenize='porter unicode61')")

    def fts5_indexes(ch):
        """Does the tokenizer produce a token for a document made only of `ch`?"""
        db.execute("DELETE FROM t")
        db.execute("INSERT INTO t(b) VALUES (?)", (ch,))
        phrase = '"' + ch.replace('"', '""') + '"'
        try:
            return (
                db.execute(
                    "SELECT count(*) FROM t WHERE t MATCH ?", (phrase,)
                ).fetchone()[0]
                > 0
            )
        except sqlite3.OperationalError:
            # A phrase FTS5 will not even parse indexes nothing, by definition.
            return False

    mismatches = []
    refused = []
    for ch in SWEEP:
        try:
            dropped = translate("kubernetes " + ch) == '"kubernetes"'
        except Fts5QueryError:
            # A LOUD refusal is the documented third outcome and is never the
            # defect class this pins — that class is always silent. `(` and `)`
            # land here, correctly: they are structure, not tokens.
            refused.append(ch)
            continue
        indexed = fts5_indexes(ch)
        # Dropping must mean exactly "the tokenizer would index nothing here".
        if dropped == indexed:
            mismatches.append(
                (repr(ch), hex(ord(ch)),
                 "dropped" if dropped else "kept",
                 "indexed" if indexed else "not-indexed")
            )

    if mismatches:
        for m in mismatches[:20]:
            print("MISMATCH %s %s: translate %s it, tokenizer %s it" % m)
        print("%d character(s) where the oracle disagrees" % len(mismatches))
        return 1
    print("ok: oracle agrees with the tokenizer over %d characters "
          "(%d refused as structure)" % (len(SWEEP) - len(refused), len(refused)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
