#!/usr/bin/env bats
# The scout's retrieval contract, post one-query redesign: query-records.sh
# --ask is the SOLE retrieval surface — ONE term set, ONE invocation — with
# the digest replay and the project-justfile probe riding that same single
# Bash call, and a record the scout can reach by hand but not by query is
# reported as a bug (UNREACHABLE) rather than routed around.
#
# The redesign retired the old auxiliary surfaces this file used to pin: the
# --cat batch read, --recall-first ordering over iterative --keyword probes,
# and the 3-4 call budget. hooks/query-shape-guard.sh now enforces the same
# shape from outside the prompt; these tests hold the PROMPTS to it from
# inside.
#
# These are prose assertions on agent prompts, which is the only place the
# contract can live — the harness reads the markdown, not a config. They pin
# the load-bearing clauses, not the wording around them. The fork binds from
# skills/how-do-i/SKILL.md; agents/procedure-scout.md governs direct
# Agent-tool spawns and must carry the same clauses.
#
# Run: bats hooks/tests/scout-retrieval.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  REPO="$PLUGIN/../.."
  AGENT="$PLUGIN/agents/procedure-scout.md"
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
  SCRIPT="$PLUGIN/scripts/query-records.sh"
  GATE="$PLUGIN/hooks/how-do-i-gate.sh"
  # shellcheck source=../../scripts/lib/frontmatter.sh
  source "$PLUGIN/scripts/lib/frontmatter.sh"
}

fm_key() { fm_value "$(frontmatter_block "$1")" "$2"; }

# ---------- the sole retrieval surface is the --ask front door ----------

@test "the scout body carries no free-form recursive grep fallback" {
  # `grep -rn '^keywords:' .../references/procedures/` was the documented
  # escape hatch when keyword search missed. It is exactly the silent
  # workaround that hides a keywords/matcher bug, and it reads a store subset
  # the query already covers.
  # Scoped to RUNNABLE lines (fenced bash blocks): a prohibition has to be able
  # to name the command it forbids, and a file-wide pattern would forbid the
  # Boundaries from saying "never use grep -r here".
  local offenders
  offenders="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && /grep -[a-zA-Z]*r/ { print FILENAME ":" FNR ": " $0 }
  ' "$AGENT")"
  [ -z "$offenders" ] || { echo "recursive grep fallback still in the scout:"; echo "$offenders"; false; }
}

@test "the scout body does not send the scout to find(1) for retrieval" {
  # Fence-scoped for the same reason the grep check above is: a file-wide
  # pattern also matches PROSE that names the command.
  local offenders
  offenders="$(awk '
    /^[[:space:]]*```bash/ { inblock=1; next }
    /^[[:space:]]*```/     { inblock=0; next }
    inblock && /(^|[^[:alnum:]_.\/-])find[[:space:]]/ { print FNR ": " $0 }
  ' "$AGENT")"
  [ -z "$offenders" ] || { echo "find(1) retrieval still in the scout:"; echo "$offenders"; false; }
}

@test "the scout body carries no raw awk batch-read recipe" {
  # Superseded first by --cat, then by the one-shot --ask dump: every matched
  # record comes back IN FULL inside the single call, so there is no reading
  # step left for awk to serve. Left in place it is a second retrieval
  # surface, and the one that can read outside the record stores.
  run grep -n "FNR==1" "$AGENT"
  [ "$status" -ne 0 ] || { echo "raw awk batch-read still in the scout: $output"; false; }
}

@test "no prompt issues a retired retrieval mode as a command" {
  # The one-query redesign retired the scout's auxiliary surfaces: --cat
  # batching, --recall-first ordering, iterative --keyword probes, id pulls.
  # A Boundary may NAME them to forbid them; they may never appear as a
  # command either fork RUNS. Fence-scoped so the prohibition prose cannot
  # trip it.
  local f offenders
  for f in "$SKILL" "$AGENT"; do
    offenders="$(awk '
      /^[[:space:]]*```bash/ { inblock=1; next }
      /^[[:space:]]*```/     { inblock=0; next }
      inblock && /--cat|--keyword|--recall|--id/ { print FILENAME ":" FNR ": " $0 }
    ' "$f")"
    [ -z "$offenders" ] || { echo "retired retrieval mode runnable in $(basename "$f"):"; echo "$offenders"; false; }
  done
}

@test "every runnable line in both prompts is a sanctioned one-shot shape" {
  # The runnable surface must be exactly what hooks/query-shape-guard.sh lets
  # through: the digest replay, the single --ask query, and the justfile
  # probe (command -v just / just --dump / its jq stage). Anything else
  # runnable sanctions a second retrieval or mutation surface behind the
  # guard's back.
  local f blocks offenders
  for f in "$SKILL" "$AGENT"; do
    blocks="$(grep -cE '^[[:space:]]*```bash' "$f" || true)"
    [ "$blocks" -ge 1 ] || { echo "$(basename "$f"): no bash blocks — assertion would pass vacuously"; false; }
    offenders="$(awk '
      /^[[:space:]]*```bash/ { inblock=1; next }
      /^[[:space:]]*```/     { inblock=0; next }
      inblock && $0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/ &&
      $0 !~ /query-records\.sh/ && $0 !~ /session-digest-read\.sh/ &&
      $0 !~ /just/ && $0 !~ /jq -r/ { print FILENAME ":" FNR ": " $0 }
    ' "$f")"
    [ -z "$offenders" ] || { echo "unsanctioned runnable line in $(basename "$f"):"; echo "$offenders"; false; }
  done
}

@test "query-records.sh is invoked in one mode only: --ask" {
  # Every fence line that runs the tool must be the front door. A bare
  # query-records.sh line would let another flag ride a future edit.
  local f bad
  for f in "$SKILL" "$AGENT"; do
    bad="$(awk '
      /^[[:space:]]*```bash/ { inblock=1; next }
      /^[[:space:]]*```/     { inblock=0; next }
      inblock && /query-records\.sh/ && $0 !~ /--ask/ { print FILENAME ":" FNR ": " $0 }
    ' "$f")"
    [ -z "$bad" ] || { echo "$(basename "$f"): query-records.sh invoked outside --ask:"; echo "$bad"; false; }
  done
}

@test "the fork prompt mandates the --ask front door as its one retrieval act" {
  grep -qF -- '--ask' "$SKILL" \
    || { echo "SKILL.md never names --ask; the fork is never told how to retrieve"; false; }

  # Anchored, not a bare presence grep: --ask must appear as a command the
  # fork RUNS, inside a fenced bash block invoking query-records.sh.
  run awk '
    /^[[:space:]]*```bash/ { inblock = 1; next }
    /^[[:space:]]*```/     { inblock = 0; next }
    inblock && /query-records\.sh/ && /--ask/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$SKILL"
  [ "$status" -eq 0 ] \
    || { echo "--ask is mentioned in prose but never shown as a runnable command"; false; }

  grep -qiE 'only retrieval act|sole retrieval' "$SKILL" \
    || { echo "SKILL.md states no one-retrieval-act boundary"; false; }
}

@test "the sole-retrieval boundary forbids each named alternative, not retrieval in general" {
  # Read a window from the clause itself rather than grepping the whole file,
  # so an unrelated mention elsewhere cannot satisfy this. The redesigned
  # boundary enumerates BOTH the retired flags AND the raw shell tools, plus
  # the Read tool.
  local line anchor window
  line="$(grep -inE 'only retrieval act|sole retrieval (surface|act)' "$SKILL" | head -1)"
  [ -n "$line" ] \
    || { echo "SKILL.md states no sole-surface boundary — the fork may use any tool"; false; }
  anchor="$(printf '%s' "$line" | cut -d: -f1)"
  window="$(sed -n "${anchor},$((anchor + 6))p" "$SKILL")"
  local tool
  for tool in '--keyword' '--cat' '--recall' '--id' 'grep' 'find' 'ls' 'awk' 'cat' 'head' 'Read'; do
    [[ "$window" == *"$tool"* ]] \
      || { echo "the sole-retrieval boundary does not forbid '$tool': $window"; false; }
  done
}

@test "the one Bash call chains the digest replay AND the query together" {
  # Step 3 of both prompts: warm start and retrieval ride in ONE call, judged
  # as one block because the guard counts Bash CALLS, not lines. Split into
  # two calls, the digest replay doubles the bill and the query is denied.
  local f
  for f in "$SKILL" "$AGENT"; do
    run awk '
      /^[[:space:]]*```bash/ { inblock=1; buf=""; next }
      /^[[:space:]]*```/     {
        if (inblock && buf ~ /session-digest-read\.sh/ && buf ~ /--read/ \
            && buf ~ /query-records\.sh/ && buf ~ /--ask/) found=1
        inblock=0; next
      }
      inblock { buf = buf $0 "\n" }
      END { exit(found ? 0 : 1) }
    ' "$f"
    [ "$status" -eq 0 ] \
      || { echo "$(basename "$f"): digest replay and --ask do not share one command block"; false; }
  done
}

@test "neither tool grant reopens the surface the contract forbids" {
  # The agent file is where direct spawns are enforced; the skill frontmatter
  # is the fork's best-effort layer, because a fork inherits the parent
  # toolset and must disallow the read/write bypass explicitly.
  local tools disallowed forbidden
  tools="$(fm_key "$AGENT" tools)"
  [ -n "$tools" ] || { echo "no tools: key in the scout frontmatter"; false; }
  [[ "$tools" == *Bash* ]] || { echo "scout cannot run query-records.sh without Bash: $tools"; false; }
  for forbidden in Read Grep Glob Write Edit; do
    [[ "$tools" != *"$forbidden"* ]] \
      || { echo "agent tools: grants $forbidden, which the contract forbids: $tools"; false; }
  done
  disallowed="$(fm_key "$SKILL" disallowed-tools)"
  [ -n "$disallowed" ] || { echo "no disallowed-tools: key in SKILL.md frontmatter"; false; }
  for forbidden in Read Grep Glob; do
    [[ "$disallowed" == *"$forbidden"* ]] \
      || { echo "SKILL.md fails to disallow $forbidden for the fork: $disallowed"; false; }
  done
}

@test "both prompts point at --list-stores as discovery, and never run it in-fork" {
  # The redesign pulled the store-list dump OUT of the fork's budget: running
  # it inside a fork is an unsanctioned shape the guard denies (it burns the
  # one call). The boundary must still point at the discovery mechanism
  # rather than freeze a copy of the list — citation, not invocation.
  local f n
  for f in "$SKILL" "$AGENT"; do
    grep -qF -- '--list-stores' "$f" \
      || { echo "$(basename "$f"): no pointer at the store-list discovery mechanism"; false; }
    n="$(awk '/^[[:space:]]*```bash/{b=1;next} /^[[:space:]]*```/{b=0;next}
              b && /--list-stores/ { print NR; exit }' "$f")"
    [ -z "$n" ] \
      || { echo "$(basename "$f"): --list-stores is runnable at line $n — it costs a Bash call the fork does not have"; false; }
  done
}

# ---------- one query, ever ----------

@test "both prompts state the one-query budget, with no retry and an outlet" {
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qF 'exactly ONE query' "$f" \
      || { echo "$(basename "$f"): the exactly-one-query budget was lost"; false; }
    grep -qiE 'no retry|no widening|no follow-up|no second (call|query)' "$f" \
      || { echo "$(basename "$f"): the budget states no closed doors"; false; }
    # Thoroughness protection, relocated not deleted: a miss is reported as
    # UNREACHABLE, never probed around. Without the outlet the budget reads
    # as permission to answer from memory.
    grep -qF 'UNREACHABLE' "$f" \
      || { echo "$(basename "$f"): no UNREACHABLE outlet beside the budget"; false; }
  done
}

@test "the gate message agrees: the term list is complete because there is one query" {
  # Tool, gate, and prompts must state the same economy, or the blocked main
  # agent is coached into composing multi-call flows the forks are forbidden.
  grep -qiE 'exactly one query' "$GATE" \
    || { echo "gate deny message no longer says there is exactly one query"; false; }
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qiE 'exactly one query|exactly ONE query' "$f" \
      || { echo "$(basename "$f"): disagrees with the gate's one-query message"; false; }
  done
}

@test "the repo step does not spend a Bash call, so the one-query budget holds" {
  # Repo resolution is reasoning over text already in hand, not a lookup;
  # #48 bought that explicitly. If it ever costs a call, the fork has zero.
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qiE 'no bash call|costs no|without a bash call|zero bash' "$f" \
      || { echo "$(basename "$f"): repo step never says it is free"; false; }
  done
}

# ---------- an unreachable-but-real record is a bug signal ----------

@test "both prompts route a known-record miss to UNREACHABLE, for the matcher's sake" {
  # The old phrasing ("bug signal") was replaced by the same idea: reporting
  # the miss is what gets the matcher FIXED. Both halves must survive, or the
  # finding loses its addressee and degrades into a complaint.
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qF 'UNREACHABLE' "$f" \
      || { echo "$(basename "$f"): no UNREACHABLE finding for a known-record miss"; false; }
    grep -qiE '(gets|get) the matcher fixed|matcher gets fixed' "$f" \
      || { echo "$(basename "$f"): the UNREACHABLE finding no longer names fixing the matcher"; false; }
  done
}

@test "the scout is forbidden from silently routing around a query miss" {
  # POSITIONALLY anchored, not two independent whole-file greps: the
  # prohibition must live WITHIN the budget/unreachable paragraph, or it can
  # be deleted there while an unrelated rule elsewhere keeps the test green.
  # Proven by mutation on the pre-redesign version of this test.
  local f anchor window
  for f in "$SKILL" "$AGENT"; do
    anchor="$(grep -in 'UNREACHABLE' "$f" | head -1 | cut -d: -f1)"
    [ -n "$anchor" ] || { echo "$(basename "$f"): no unreachable-record clause to anchor to"; false; }
    window="$(sed -n "${anchor},$((anchor + 10))p" "$f")"
    grep -qiE 'no retry|no widening|no follow-up pull|probing around it' <<< "$window" \
      || { echo "$(basename "$f"): no routing-around prohibition within 10 lines of UNREACHABLE at line $anchor"; false; }
  done
}

@test "the output shape has somewhere to put the unreachable-record finding" {
  # A finding with no slot in the report shape is a finding that never gets
  # emitted.
  grep -qiE 'UNREACHABLE|RETRIEVAL' "$AGENT"
}

@test "the --full truncation notice points at --cat, not a raw awk recipe" {
  # Legacy callers (--full without --ask) still exist outside the forks; the
  # notice must hand them the sanctioned batch-read surface, never an awk
  # one-liner. Scoped to the notice STRING, not the whole file — print_full's
  # own implementation legitimately uses awk.
  local notice
  # `|| true` for errexit: grep exits 1 on no match, which would abort the
  # test before the vacuity guard below could print.
  notice="$(grep -n '(--full: dumped' "$SCRIPT" || true)"
  [ -n "$notice" ] || { echo "truncation notice not found — assertion would pass vacuously"; false; }
  [[ "$notice" == *"--cat"* ]] || { echo "notice does not point at --cat: $notice"; false; }
  [[ "$notice" != *"awk"* ]] || { echo "notice still advertises a raw awk batch-read: $notice"; false; }
}

# ---------- the fork prompt is SKILL.md, so the contract must live there ----------
#
# A forked skill loads SKILL.md as its prompt and takes `agent:` as identity
# only. Every binding assertion below therefore runs against $SKILL as well
# as $AGENT — parity on clauses, not wording.

@test "neither prompt claims grep as the scout's own method" {
  # Both files legitimately NAME grep in prohibitions, so the word itself is
  # not the tell. Possessive framing is.
  local f hit
  for f in "$SKILL" "$AGENT"; do
    hit="$(grep -niE 'your (greps|grepping|grep )' "$f" || true)"
    [ -z "$hit" ] \
      || { echo "$(basename "$f") advertises grep as the scout's own method: $hit"; false; }
  done
}

@test "the fork carries the UNREACHABLE bug-report contract, not a silent workaround licence" {
  grep -qF 'UNREACHABLE' "$SKILL" \
    || { echo "SKILL.md has no UNREACHABLE section; a query miss has nowhere to go"; false; }
  grep -qiE 'corpus bug|silently work around|route around' "$SKILL" \
    || { echo "SKILL.md lost the express-it-as-corpus-bug framing for unsearchable records"; false; }
}

@test "the fork prompt carries the output-shape contract" {
  local key
  for key in 'GOAL:' 'GOVERNS:' 'COMMANDS (verbatim)' 'TRAPS:' 'STANDING NOTES:' 'NOT FOUND:'; do
    grep -qF -- "$key" "$SKILL" \
      || { echo "output shape is missing '$key' — the fork has no contract to return"; false; }
  done
}

@test "the two prompts do not disagree: the agent file keeps the same contract" {
  # agents/procedure-scout.md no longer binds the fork, but it still governs a
  # direct Agent-tool spawn. Both must carry the load-bearing clauses, or one
  # caller silently gets a weaker scout.
  local key
  for key in '--ask' 'UNREACHABLE' 'query-records.sh'; do
    grep -qF -- "$key" "$SKILL" || { echo "SKILL.md lost '$key'"; false; }
    grep -qF -- "$key" "$AGENT" || { echo "procedure-scout.md lost '$key'"; false; }
  done
  grep -qiE 'only retrieval act|sole retrieval surface' "$AGENT" \
    || { echo "procedure-scout.md lost its sole-retrieval boundary"; false; }
}

@test "the agent file says plainly that it does not bind the fork" {
  # The trap this round cost us: a contributor edits the agent file, sees green
  # tests, and ships a change that never reaches production.
  grep -qiE 'does not (bind|reach)|never reaches' "$AGENT" \
    || { echo "procedure-scout.md does not warn that the fork ignores it"; false; }
  grep -qF 'SKILL.md' "$AGENT" \
    || { echo "procedure-scout.md does not point at the file that does bind"; false; }
}

# ---------- #48: resolve the target repo, never assume cwd ----------
#
# Unchanged by the one-query redesign: resolution is free reasoning, and a
# repo-scoped goal resolved against the wrong repo is still the most
# confident wrong answer this loop produces.

@test "both prompts resolve the target repo before retrieving, not from cwd by default" {
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qiE 'resolve .*repo|target repo' "$f" \
      || { echo "$(basename "$f"): no repo-resolution step at all"; false; }
    # The precedence, in order, and cwd explicitly LAST.
    grep -qiE 'goal text' "$f" || { echo "$(basename "$f"): goal text not named as a source"; false; }
    grep -qiE 'held context|context you were|already handed' "$f" \
      || { echo "$(basename "$f"): held context not named as a source"; false; }
    grep -qiE 'working directory|cwd' "$f" || { echo "$(basename "$f"): cwd not named as a source"; false; }
    # Precedence is an ORDER, not a bag of words. Asserted on the FLATTENED
    # text: a line-by-line check reads whichever mention happens to come first
    # on its own line, so wrapping across a break was enough to hide a fully
    # inverted list from an earlier draft. Prefix-before-match length is the
    # index of each phrase.
    local flat g h c
    flat="$(tr '\n' ' ' < "$f" | tr -s ' ')"
    g="${flat%%goal text*}"; h="${flat%%held context*}"; c="${flat%%working directory*}"
    [ "${#g}" -lt "${#h}" ] \
      || { echo "$(basename "$f"): held context is offered before goal text"; false; }
    [ "${#h}" -lt "${#c}" ] \
      || { echo "$(basename "$f"): the working directory is offered before held context"; false; }
    # Resolution must come BEFORE any retrieval mention — the repo has to be
    # settled before the one query is issued. The first `--recall` token in
    # the file sits in the Boundary that forbids it, which is still downstream
    # of step 1, so it remains a valid retrieval marker.
    local s r
    s="${flat%%Resolve the target repo*}"; r="${flat%%--recall*}"
    [ "${#s}" -lt "${#r}" ] \
      || { echo "$(basename "$f"): repo resolution comes AFTER retrieval"; false; }
    # Never silently.
    grep -qiE 'never .*(assume|default).*(cwd|working directory)|cwd .*never' "$f" \
      || { echo "$(basename "$f"): nothing forbids silently defaulting to cwd"; false; }
    # Held context is scoped to the CURRENT goal. Unscoped, it lets a digest
    # from an unrelated prior goal supply the repo — a stale answer that still
    # looks fully sourced.
    grep -qE 'CURRENT goal' "$f" \
      || { echo "$(basename "$f"): held context is not scoped to the current goal"; false; }
    grep -qiE 'not a repo source' "$f" \
      || { echo "$(basename "$f"): an unrelated prior goal's digest is not excluded as a repo source"; false; }
  done
}

@test "both prompts require STATING the repo source, on a template that names the sources" {
  local f
  for f in "$SKILL" "$AGENT"; do
    grep -qiE 'state which|which one you used|say which' "$f" \
      || { echo "$(basename "$f"): resolution is never reported to the caller"; false; }
    grep -qF 'REPO: <owner/repo>  [from goal text|from held context|from cwd]' "$f" \
      || { echo "$(basename "$f"): REPO: template missing, or no longer names its source"; false; }
    local src
    for src in 'from goal text' 'from held context' 'from cwd'; do
      grep -qF "$src" "$f" \
        || { echo "$(basename "$f"): REPO: template no longer offers '$src'"; false; }
    done
  done
}

# ---------- the project-justfile probe (procedures x just integration) ----------
#
# Still an ADDITION, not a second retrieval surface — but under the one-query
# budget it rides INSIDE the single Bash call instead of costing its own.

@test "both prompts probe the project justfile after the query, before the return" {
  local f b j v
  for f in "$SKILL" "$AGENT"; do
    b="$(awk '/^[[:space:]]*```bash/{bl=1;next} /^[[:space:]]*```/{bl=0;next}
              bl && /query-records\.sh/ && /--ask/ { print NR; exit }' "$f")"
    j="$(awk '/^[[:space:]]*```bash/{bl=1;next} /^[[:space:]]*```/{bl=0;next}
              bl && /--dump/ { print NR; exit }' "$f")"
    v="$(grep -n '^5\. ' "$f" | head -1 | cut -d: -f1)"
    [ -n "$b" ] || { echo "$(basename "$f"): no --ask block to anchor against"; false; }
    [ -n "$j" ] || { echo "$(basename "$f"): the justfile dump is never issued as a command"; false; }
    [ -n "$v" ] || { echo "$(basename "$f"): no return step to anchor against"; false; }
    { [ "$b" -lt "$j" ] && [ "$j" -lt "$v" ]; } \
      || { echo "$(basename "$f"): the probe (line $j) is not between the query (line $b) and the return (line $v)"; false; }
  done
}

@test "both prompts soft-degrade the justfile probe and never report its absence as a miss" {
  # A missing just(1) or justfile is a normal environment, not a gap: if the
  # degrade were reported, every non-just repo would grow a phantom
  # UNREACHABLE. Matched on FLATTENED text — both files wrap these clauses
  # across lines ("never a retrieval / miss"), and grep is line-based.
  local f flat
  for f in "$SKILL" "$AGENT"; do
    flat="$(tr '\n' ' ' < "$f" | tr -s ' ')"
    grep -qiE 'skip it silently|soft-degrade' "$f" \
      || { echo "$(basename "$f"): the justfile probe does not soft-degrade"; false; }
    [[ "$flat" == *"never a retrieval miss"* ]] \
      || { echo "$(basename "$f"): a skipped probe is not kept distinct from a retrieval miss"; false; }
  done
}

@test "both prompts put matched recipes under RECIPES, preferred over raw commands" {
  local f co re tr
  for f in "$SKILL" "$AGENT"; do
    grep -qF 'preferred over reciting equivalent raw commands' "$f" \
      || { echo "$(basename "$f"): RECIPES carries no preference over raw commands"; false; }
    co="$(grep -n 'COMMANDS (verbatim)' "$f" | head -1 | cut -d: -f1)"
    re="$(grep -n '^RECIPES' "$f" | head -1 | cut -d: -f1)"
    tr="$(grep -n '^TRAPS:' "$f" | head -1 | cut -d: -f1)"
    [ -n "$co" ] && [ -n "$re" ] && [ -n "$tr" ] \
      || { echo "$(basename "$f"): output-shape anchors missing"; false; }
    { [ "$co" -lt "$re" ] && [ "$re" -lt "$tr" ]; } \
      || { echo "$(basename "$f"): RECIPES is not adjacent to COMMANDS (before TRAPS:)"; false; }
  done
}

@test "the just-dump exemption stays anchored to a written carve-out in both boundaries" {
  # The sanctioned-shapes test exempts just/jq lines. Without this companion,
  # deleting the boundary clause that licenses the exemption would leave it
  # free-floating — an unanchored exception is how a second retrieval surface
  # grows back. The redesign collapsed the old two boundaries into one per
  # file, so ONE written carve-out per file is the anchor now.
  local f n bnd
  for f in "$SKILL" "$AGENT"; do
    n="$(grep -cF 'cwd-resolving justfile' "$f")"
    [ "$n" -ge 1 ] \
      || { echo "$(basename "$f"): no written carve-out for the just-dump exemption"; false; }
    bnd="$(grep -n '^# Boundaries' "$f" | head -1 | cut -d: -f1)"
    [ -n "$bnd" ] || { echo "$(basename "$f"): no Boundaries section to anchor within"; false; }
    local occ
    occ="$(grep -nF 'cwd-resolving justfile' "$f" | head -1 | cut -d: -f1)"
    [ "$occ" -gt "$bnd" ] \
      || { echo "$(basename "$f"): carve-out at line $occ sits outside Boundaries (section starts line $bnd)"; false; }
  done
}

@test "the justfile probe rides the SAME call, costing no extra query" {
  # The old budget charged +1 for the probe; the redesign folds it into the
  # single Bash call. The prompt must say so, or a fork pays (and the guard
  # denies) a call the design already spent. Flattened text again: both files
  # wrap the clause ("the SAME / call:").
  local f flat
  for f in "$SKILL" "$AGENT"; do
    flat="$(tr '\n' ' ' < "$f" | tr -s ' ')"
    [[ "$flat" == *"append the probe to the SAME call"* ]] \
      || { echo "$(basename "$f"): the probe is not stated to ride the same call"; false; }
  done
}

# ---------- #22 AC-4: every declaring agent, not just the scout ----------

@test "AC-4: every agent declaring model: that a skill forks is pinned by that skill" {
  # Generalises the procedures-only check in gate-skill-model.bats across every
  # plugin: enumerate the declaring agents (the issue's own sweep,
  # `grep -l '^model:' plugins/*/agents/*.md`), then require the fork skill
  # that dispatches each one to re-declare the same tier — because the fork
  # path reads the SKILL's model, never the agent's.
  local declaring checked=0
  declaring="$(grep -l '^model:' "$REPO"/plugins/*/agents/*.md 2>/dev/null || true)"
  [ -n "$declaring" ] || { echo "no agent declares model: — the sweep found nothing to check"; false; }

  local a agent_name agent_model s skill_model
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    agent_name="$(basename "$a" .md)"
    agent_model="$(fm_key "$a" model)"
    for s in "$REPO"/plugins/*/skills/*/SKILL.md; do
      [ "$(fm_key "$s" agent)" = "$agent_name" ] || continue
      [ "$(fm_key "$s" context)" = "fork" ] || continue
      skill_model="$(fm_key "$s" model)"
      [ "$skill_model" = "$agent_model" ] || {
        echo "$s forks $agent_name but pins '$skill_model' against the agent's '$agent_model'"
        false
      }
      checked=$((checked + 1))
    done
  done <<< "$declaring"

  [ "$checked" -ge 2 ] || { echo "expected at least the two gate forks, checked $checked"; false; }
}

# ---------- #22 AC-6: the inheritance is design, and is recorded as such ----------

@test "AC-6: the README records fork-model inheritance as documented harness design" {
  local README="$REPO/README.md"
  grep -qiE 'documented (harness )?(design|behaviour|behavior)' "$README"
  grep -qF 'sub-agents' "$README"
}
