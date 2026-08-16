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
    while ((getline t < tokfile) > 0) {
        if (t == "") continue
        nparts = split(t, PARTS, /[^a-z0-9]+/)
        re = ""
        for (p = 1; p <= nparts; p++) {
            if (PARTS[p] == "") continue
            re = (re == "") ? PARTS[p] : re "[^a-z0-9\n]+" PARTS[p]
        }
        if (re != "") RE[++ntok] = "(^|[^a-z0-9])" re "($|[^a-z0-9])"
    }
    close(tokfile)
}

# Value of "key":"..." in line, JSON-escape-aware (stops at the first
# unescaped quote). Tolerates whitespace around the colon — the file mixes
# `"k":"v"` and `"k": "v"` records. Returns "" when the key is absent or
# non-string.
function fieldval(line, key,    rest, len, i, c, out, esc) {
    if (!match(line, "\"" key "\"[ \t]*:[ \t]*\"")) return ""
    rest = substr(line, RSTART + RLENGTH)
    len = length(rest); out = ""; esc = 0
    for (i = 1; i <= len; i++) {
        c = substr(rest, i, 1)
        if (esc) { out = out c; esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") return out
        out = out c
    }
    return out
}

{
    # Fields are joined with \n and phrase joints match [^a-z0-9\n]+, so a
    # phrase cannot match across a field boundary (pattern ending "check" +
    # description starting "run" must not satisfy "check-run").
    hay = ""
    for (f = 1; f <= nfields; f++) hay = hay "\n" fieldval($0, FIELDS[f])
    hay = tolower(hay)
    for (t = 1; t <= ntok; t++) if (match(hay, RE[t])) { print; next }
}
