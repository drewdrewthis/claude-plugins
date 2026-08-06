# record-scan.awk — single-pass structural scan over record files.
# vendored from orchard-codex fix/how-do-i-lookup-speed@c873be76 (pre-merge)
#
# Reads every file passed as an argument, parses only the frontmatter block
# plus enough body to compute the gloss, and emits one TSV line per file
# passing the structural filters:
#
#     path \t gloss
#
# Filters (all optional, AND logic), passed with -v:
#   qkind  — frontmatter `kind:` must equal this exactly
#   qid    — frontmatter `id:` must equal this exactly
#   qlinks — frontmatter `links:` must reference this id token
#
# Replaces the per-file bash/awk fork loop (fm_value called per key per file):
# one process for the whole corpus instead of ~2N forks.
#
# Known behavior change vs the fork loop: a 0-byte file is silently skipped
# (awk never reads a line from it, so it is never emitted). The old loop
# would have listed an empty file on a filterless narrowing pass. Records are
# never legitimately empty; an empty record is a bug upstream, not a result.

BEGIN { qkind = qkind ""; qid = qid ""; qlinks = qlinks "" }

FNR == 1 {
    # flush the previous file
    if (NR > 1) emit()
    infm = 0; fmdone = 0
    id = ""; kind = ""; links = ""; gloss = ""
    fpath = FILENAME
    if ($0 == "---") { infm = 1; next }
    fmdone = 1
    # fall through: line 1 is already body
}

infm == 1 {
    if ($0 == "---") { infm = 0; fmdone = 1; next }
    # PLUGIN ADAPTATION: quoted-scalar fix ahead of upstream (CodeRabbit PR #5); upstream orchard-codex#268-phase-2 inherits
    if ($0 ~ /^id:/)    { id = $0;    sub(/^id:[[:space:]]*/, "", id);    sub(/[[:space:]].*$/, "", id);    id = stripq(id) }
    if ($0 ~ /^kind:/)  { kind = $0;  sub(/^kind:[[:space:]]*/, "", kind); sub(/[[:space:]].*$/, "", kind); kind = stripq(kind) }
    if ($0 ~ /^links:/) { links = $0; sub(/^links:[[:space:]]*/, "", links) }
    next
}

# body: first heading, else first non-empty line, then skip the rest of the file
gloss == "" {
    if ($0 ~ /^#+[[:space:]]/) {
        g = $0; sub(/^#+[[:space:]]*/, "", g); gloss = g; nextfile
    }
    if ($0 ~ /[^[:space:]]/) { gloss = $0; nextfile }
    next
}

{ nextfile }

END { if (NR > 0) emit() }

function emit(   g, n, toks, i, t, found) {
    if (qkind != "" && kind != qkind) return
    if (qid   != "" && id   != qid)   return
    if (qlinks != "") {
        g = links
        gsub(/[{}\[\],]/, " ", g)
        n = split(g, toks, /[[:space:]]+/)
        found = 0
        for (i = 1; i <= n; i++) {
            t = toks[i]
            gsub(/["']/, "", t)
            # sub-key names ("decisions:") carry a trailing colon; ids never do
            if (t == qlinks) { found = 1; break }
        }
        if (!found) return
    }
    g = gloss
    gsub(/[[:space:]]+/, " ", g)
    sub(/^ /, "", g); sub(/ $/, "", g)
    if (length(g) > 90) g = substr(g, 1, 87) "..."
    if (g == "") g = "(record)"
    printf "%s\t%s\n", fpath, g
}

# strips one matching pair of outer quotes (double or single) from an
# already-trimmed id/kind scalar, so a quoted YAML value compares equal to
# an unquoted query token.
function stripq(v,   n) {
    n = length(v)
    if (n < 2) return v
    if (substr(v, 1, 1) == "\"" && substr(v, n, 1) == "\"") return substr(v, 2, n - 2)
    if (substr(v, 1, 1) == "'"  && substr(v, n, 1) == "'")  return substr(v, 2, n - 2)
    return v
}
