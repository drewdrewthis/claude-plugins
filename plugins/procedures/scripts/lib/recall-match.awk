# recall-match.awk — field-anchored substring match over mistakes.jsonl.
#
# PLUGIN ADAPTATION: no upstream source — the plugin is the source of truth
# for query-records machinery post orchard-codex#268 phase 1.
#
# Input: JSON-lines records on stdin/files. Var: tokfile (one lowercase token
# per line, pre-tokenized by the caller the same way --keyword tokenizes).
#
# A line matches when ANY token appears as a substring inside the VALUE of one
# of the semantic fields below. Matching never sees keys, paths, URLs, session
# ids, or refs — the whole point over a raw `grep -i` of the file, whose
# unanchored matches inside paths/URLs made broad recall sweeps return noise.
#
# Emits matching lines unchanged, in file order (mistakes.jsonl is
# append-only, so file order IS chronological order).

BEGIN {
    nfields = split("pattern description correction face category skill summary what fix", FIELDS, " ")
    # Each tokfile line is a lowercase TERM: a whole word, or a phrase whose
    # words are joined by punctuation ("pickup-loop"). Build one regex per
    # term: word-boundary anchored, with any punctuation run inside the term
    # matching any separator run in the text — so "pickup-loop" matches
    # "pickup loop" and "pickup-loop" as a phrase, never bare "loop", and
    # "type.slot" never matches a lone "type". Whole-word + phrase matching is
    # the precision fix over substring OR-union, which matched most of the
    # file on common words.
    # The term's alphanumeric PARTS ride along as a cheap prefilter: a line
    # that does not contain every part (lowercased) cannot match the term's
    # regex anywhere — its values are substrings of the line — so the field
    # extraction and regex pass are skipped for it entirely.
    while ((getline t < tokfile) > 0) {
        if (t == "") continue
        nparts = split(t, PARTS, /[^a-z0-9]+/)
        re = ""; np = 0
        for (p = 1; p <= nparts; p++) {
            if (PARTS[p] == "") continue
            np++
            TKPART[ntok + 1, np] = PARTS[p]
            re = (re == "") ? PARTS[p] : re "[^a-z0-9\n]+" PARTS[p]
        }
        if (re != "") {
            ntok++
            TPARTS[ntok] = np
            RE[ntok] = "(^|[^a-z0-9])" re "($|[^a-z0-9])"
        }
    }
    close(tokfile)
}

# Value of "key":"..." in line, JSON-escape-aware (stops at the first
# unescaped quote). Tolerates whitespace around the colon — the file mixes
# `"k":"v"` and `"k": "v"` records. Returns "" when the key is absent or
# non-string. One anchored ERE ("([^"\\]|\\.)*") replaces the per-character
# scan this used to be — that loop was the recall sweep's hot spot.
function fieldval(line, key,    rest) {
    if (!match(line, "\"" key "\"[ \t]*:[ \t]*\"")) return ""
    rest = substr(line, RSTART + RLENGTH)
    if (!match(rest, /^([^"\\]|\\.)*/)) return ""
    return substr(rest, 1, RLENGTH)
}

{
    # prefilter: keep only terms whose parts all occur somewhere in the line.
    ncand = 0
    low = tolower($0)
    for (t = 1; t <= ntok; t++) {
        ok = 1
        for (p = 1; p <= TPARTS[t]; p++) {
            if (!index(low, TKPART[t, p])) { ok = 0; break }
        }
        if (ok) CAND[++ncand] = t
    }
    if (ncand == 0) next

    # Fields are joined with \n and phrase joints match [^a-z0-9\n]+, so a
    # phrase cannot match across a field boundary (pattern ending "check" +
    # description starting "run" must not satisfy "check-run").
    hay = ""
    for (f = 1; f <= nfields; f++) hay = hay "\n" fieldval($0, FIELDS[f])
    hay = tolower(hay)
    for (c = 1; c <= ncand; c++) if (match(hay, RE[CAND[c]])) { print; break }
}
