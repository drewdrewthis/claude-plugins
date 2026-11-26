#!/usr/bin/env bash
# record-hints.sh — list the records whose frontmatter shares words with a
# prompt, so an agent knows they exist and can open them.
#
# PLUGIN ADAPTATION: no upstream counterpart — called by hooks/nudge.sh.
#
# SINGLE RESPONSIBILITY: prompt text (stdin) -> at most RECORD_HINTS_MAX
# "id — summary" lines (stdout). Never loads a record body, never calls a
# model: it runs on every prompt and must stay well under a second (owner
# decision dec.2026-11-26-agent-system-revamp-steps-3-6). The agent reading
# the hint judges whether a record applies; this script only finds candidates.
#
# Usage: record-hints.sh < prompt.txt
#
# Roots and stores come from lib/stores.sh (_stores_resolve_roots_spec /
# _stores_discover), the same discovery build-record-index.sh uses, with the
# same exclusions (node_modules, EVOLUTION.md, INDEX.md, <records-dir>/plans,
# frontmatter with user-invocable:).
#
# Match: prompt words of 4+ characters, minus stopwords, with a plural "s"
# stripped, compared as whole words against each record's id, keywords and
# description (title, then purpose, when there is no description). Each shared
# word adds log(N/df), so a word in every record counts for almost nothing; id
# and keyword hits count 1.5x. A record needs RECORD_HINTS_MIN_TERMS distinct
# shared words (default 2) — one shared word is mostly noise on a corpus this
# size.
#
# Output: nothing when no record qualifies. Otherwise a header naming the
# roots, then one line per record, best first. Exit 0 on every path; a
# failure prints nothing.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=lib/stores.sh
. "$SCRIPT_DIR/lib/stores.sh" 2>/dev/null || exit 0

MAX="${RECORD_HINTS_MAX:-5}"
MIN_TERMS="${RECORD_HINTS_MIN_TERMS:-2}"
case "$MAX" in ''|*[!0-9]*) MAX=5 ;; esac
case "$MIN_TERMS" in ''|*[!0-9]*) MIN_TERMS=2 ;; esac

PROMPT="$(cat 2>/dev/null || true)"
[ -n "$PROMPT" ] || exit 0

SPEC="$(_stores_resolve_roots_spec 2>/dev/null)"
[ -n "$SPEC" ] || exit 0
_stores_split_roots "$SPEC"

FILES=""
ROOTS_SHOWN=""
for root in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
    [ -d "$root" ] || continue
    cd "$root" 2>/dev/null || continue
    _stores_discover
    for s in ${STORES[@]+"${STORES[@]}"}; do
        [ "$s" = "$RECORDS_ROOT/plans" ] && continue
        [ -d "$s" ] || continue
        found="$(find "$PWD/$s" -type f -name '*.md' \
                    ! -path '*/node_modules/*' \
                    ! -name 'EVOLUTION.md' \
                    ! -name 'INDEX.md' 2>/dev/null)"
        [ -n "$found" ] && FILES="${FILES}${found}
"
    done
    case "$root" in
        "$HOME"/*) ROOTS_SHOWN="${ROOTS_SHOWN} ~${root#"$HOME"}" ;;
        *)         ROOTS_SHOWN="${ROOTS_SHOWN} $root" ;;
    esac
done
[ -n "$FILES" ] || exit 0

HITS="$(printf '%s' "$FILES" | PROMPT="$PROMPT" awk -v max="$MAX" -v minterms="$MIN_TERMS" '
function norm(w) {
    if (w ~ /ies$/ && length(w) > 4) return substr(w, 1, length(w) - 3) "y"
    if (w ~ /[^s]s$/ && length(w) > 4) return substr(w, 1, length(w) - 1)
    return w
}
# Words of 4+ chars, lowercased, split on anything not a letter or digit,
# as a " w1 w2 " set string (index() lookups beat arrays per record here).
function wordset(s,   n, i, a, w, out) {
    s = tolower(s)
    gsub(/[^a-z0-9]+/, " ", s)
    n = split(s, a, " ")
    out = " "
    for (i = 1; i <= n; i++) {
        if (length(a[i]) < 4) continue
        w = norm(a[i])
        if (index(out, " " w " ") == 0) out = out w " "
    }
    return out
}
function stripq(v,   n) {
    n = length(v)
    if (n >= 2 && (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == "'\''") && substr(v, n, 1) == substr(v, 1, 1)) return substr(v, 2, n - 2)
    return v
}
function value(line, key) { sub("^" key ":[[:space:]]*", "", line); return line }
# Reads one record up to the end of its frontmatter. One awk process reads
# every path itself (paths arrive on stdin): xargs would split a large corpus
# across several awk runs, each with its own N and df, and the merged scores
# would not be comparable. getline also returns -1 on an unreadable file, so
# that file is skipped here instead of aborting the run.
function readrec(f,   line, ln, infm, closed, userinv, field, id, desc, title, purpose, kw, c, summ) {
    ln = 0; infm = 0; closed = 0; userinv = 0; field = ""
    id = ""; desc = ""; title = ""; purpose = ""; kw = ""
    while ((getline line < f) > 0) {
        ln++
        if (ln == 1) { if (line != "---") break; infm = 1; continue }
        if (line == "---") { closed = 1; break }
        if (line ~ /^user-invocable:/) { userinv = 1; field = ""; continue }
        if (line ~ /^id:/)          { id = value(line, "id"); sub(/[[:space:]].*$/, "", id); id = stripq(id); field = ""; continue }
        if (line ~ /^description:/) { desc = value(line, "description"); field = "desc"; continue }
        if (line ~ /^title:/)       { title = value(line, "title"); field = ""; continue }
        if (line ~ /^purpose:/)     { purpose = value(line, "purpose"); field = ""; continue }
        if (line ~ /^keywords:/)    { kw = value(line, "keywords"); field = "kw"; continue }
        if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) { field = ""; continue }
        if (field == "desc") { c = line; sub(/^[[:space:]]+/, "", c); if (c != "") desc = desc " " c; continue }
        if (field == "kw")   { kw = kw " " line; continue }
    }
    close(f)
    if (!closed || userinv || id == "") return
    summ = desc != "" ? desc : (title != "" ? title : purpose)
    summ = stripq(summ)
    gsub(/[[:space:]]+/, " ", summ)
    if (summ == "") return
    N++
    rid[N] = id
    rsum[N] = summ
    rstrong[N] = wordset(id " " kw)
    rall[N] = wordset(id " " kw " " summ)
}
BEGIN {
    split("this that with have from what when make want need please could would should there their about into then than them they will just like also some more only your been were which does doing done here each other these those very much many such over after before because while where being still even most both same again once under between through during without within upon onto thing things something anything know think sure look going really okay thank thanks hello let lets cant dont wont didnt isnt", sw, " ")
    for (i in sw) stop[sw[i]] = 1
    p = tolower(ENVIRON["PROMPT"])
    gsub(/[^a-z0-9]+/, " ", p)
    n = split(p, a, " ")
    T = 0
    for (i = 1; i <= n; i++) {
        if (length(a[i]) < 4 || (a[i] in stop)) continue
        w = norm(a[i])
        if (w in seen) continue
        seen[w] = 1
        term[++T] = w
    }
    if (T == 0) exit 0
}
$0 != "" { readrec($0) }
END {
    if (T == 0 || N == 0) exit 0
    for (t = 1; t <= T; t++) {
        df[t] = 0
        for (r = 1; r <= N; r++) if (index(rall[r], " " term[t] " ")) df[t]++
    }
    for (r = 1; r <= N; r++) {
        hits = 0; s = 0
        for (t = 1; t <= T; t++) {
            if (df[t] == 0 || !index(rall[r], " " term[t] " ")) continue
            hits++
            s += log(N / df[t]) * (index(rstrong[r], " " term[t] " ") ? 1.5 : 1)
        }
        if (hits >= minterms) printf "%.4f\t%s\t%s\n", s, rid[r], rsum[r]
    }
}' 2>/dev/null | sort -t "$(printf '\t')" -k1,1gr -k2,2 | head -n "$MAX")" || true
[ -n "$HITS" ] || exit 0

echo "Related records — open one if it applies (grep -rl '^id: <id>'${ROOTS_SHOWN}):"
printf '%s\n' "$HITS" | awk -F'\t' '{
    s = $3
    if (length(s) > 100) s = substr(s, 1, 97) "..."
    printf "  %s — %s\n", $2, s
}'
exit 0
