#!/usr/bin/env bats
# Tests for scripts/commit-records.sh — the deterministic admissibility gate.
# PLUGIN ADAPTATION: no upstream counterpart — tests for new librarian commit-gate machinery.
# One case per testable AC (AC1–AC9, AC13–AC22). Each builds a tmp git root as
# a fixture (records/ tree) so the live corpus is never touched. Push is skipped
# with COMMIT_RECORDS_NO_PUSH=1 except AC15/AC21/AC22, which use a real bare remote.
# Run: bats hooks/tests/commit-records.bats

# setup — fresh tmp fixture: an isolated state dir plus a git root with a
# committed anchor record ($ROOT). Runs before every test.
setup() {
  GATE="$BATS_TEST_DIRNAME/../../scripts/commit-records.sh"
  FIX="$(mktemp -d)"
  export PROCEDURES_STATE_DIR="$FIX/state"
  QUEUE="$PROCEDURES_STATE_DIR/grooming-queue.md"
  ROOT="$FIX/root"
  _init_root "$ROOT"
}
# teardown — remove the tmp fixture tree. Runs after every test.
teardown() { rm -rf "$FIX"; }

# _init_root <dir> — git repo with a committed valid anchor record. Global git
# hooks are disabled (core.hooksPath) so an ambient pre-commit cannot interfere.
_init_root() {
  local d="$1"
  mkdir -p "$d/records/failure-modes" "$d/records/decisions"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.com
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.hooksPath /dev/null
  _fm "$d/records/failure-modes/anchor.md" fm.anchor
  git -C "$d" add -A
  git -C "$d" commit -qm anchor
}

# _fm <path> <id> [mistake-body] — a canonical valid failure-mode record whose
# slug matches its filename (so normalize does not rename it).
_fm() {
  cat > "$1" <<EOF
---
id: $2
kind: failure-mode
date: 2026-09-05
keywords: [quokka]
links: {}
status: active
description: a clean baseline failure-mode record for the gate fixture here now.
---
# rec

## Mistake
${3:-x}

## Correct
y
EOF
}

# _run_gate <args…> — run the gate with push skipped (COMMIT_RECORDS_NO_PUSH=1).
_run_gate() {  # COMMIT_RECORDS_NO_PUSH by default
  COMMIT_RECORDS_NO_PUSH=1 run bash "$GATE" "$@"
}
# _commit_count — number of commits on HEAD in $ROOT.
_commit_count() { git -C "$ROOT" rev-list --count HEAD; }

# _remote_fixture <remote-rel-path> <remote-id> — build a bare remote plus a
# clone A whose pre-push hook, on the FIRST push only, advances the remote by
# committing a record at <remote-rel-path> with id <remote-id>, then exits 0 so
# git rejects A's push as non-fast-forward. Sets REMOTE, A, HK for the caller.
_remote_fixture() {
  local rpath="$1" rid="$2"
  REMOTE="$FIX/remote.git"; git init -q --bare -b main "$REMOTE"
  A="$FIX/A"; git clone -q "$REMOTE" "$A" 2>/dev/null
  git -C "$A" config user.email t@t.com; git -C "$A" config user.name t
  git -C "$A" config commit.gpgsign false
  HK="$FIX/hooks"; mkdir -p "$HK"; git -C "$A" config core.hooksPath "$HK"
  mkdir -p "$A/records/failure-modes"; _fm "$A/records/failure-modes/seed.md" fm.seed
  git -C "$A" add -A; git -C "$A" commit -qm seed; git -C "$A" push -qu origin main
  cat > "$HK/pre-push" <<EOF
#!/usr/bin/env bash
set -e
FLAG="$FIX/.pushed_once"
[ -f "\$FLAG" ] && exit 0
touch "\$FLAG"
C="$FIX/C"; rm -rf "\$C"; git clone -q "$REMOTE" "\$C"
git -C "\$C" config user.email t@t.com; git -C "\$C" config user.name t; git -C "\$C" config commit.gpgsign false
mkdir -p "\$C/$(dirname "$rpath")"
printf -- '---\nid: $rid\nkind: failure-mode\ndate: 2026-09-05\nkeywords: [k]\nlinks: {}\nstatus: active\ndescription: upstream record injected by the push-retry rebase fixture here now.\n---\n# rec\n## Mistake\nREMOTE\n## Correct\ny\n' > "\$C/$rpath"
git -C "\$C" add -A; git -C "\$C" commit -qm remote-add; git -C "\$C" push -q
exit 0
EOF
  chmod +x "$HK/pre-push"
}

# ---- AC1: malformed frontmatter blocks, no commit, actionable queue ----
@test "AC1: missing required key blocks, no commit, queue names record+root+check" {
  _fm "$ROOT/records/failure-modes/bad.md" fm.bad
  sed -i.bak '/^status:/d' "$ROOT/records/failure-modes/bad.md"; rm -f "$ROOT"/records/failure-modes/*.bak
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/bad.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [ "$(_commit_count)" -eq "$before" ]
  grep -q "bad.md" "$QUEUE"
  grep -q "root: $ROOT" "$QUEUE"
  grep -q "check:" "$QUEUE"
}

# ---- AC2: sanitization leak blocks; clean commits ----
@test "AC2: a leaking record blocks the commit" {
  _fm "$ROOT/records/failure-modes/leak.md" fm.leak
  printf 'path: /Users/alice/secret\n' >> "$ROOT/records/failure-modes/leak.md"
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/leak.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [sanitization]"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC3: duplicate id among the changed paths blocks ----
@test "AC3: two records sharing an id block the commit" {
  _fm "$ROOT/records/failure-modes/one.md" fm.one
  _fm "$ROOT/records/failure-modes/two.md" fm.one   # same id
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/one.md records/failure-modes/two.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate id"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC4: normalize canonicalizes a non-canonical record and is idempotent ----
@test "AC4: normalize rewrites non-canonical input and second pass is byte-identical" {
  # deliberately non-canonical: keys out of order, trailing ws, empty links,
  # filename slug not matching id.
  cat > "$ROOT/records/failure-modes/messy.md" <<'EOF'
---
status: active
kind: failure-mode
id: fm.tidy-slug
date: 2026-09-05
keywords: [k]
description: deliberately non-canonical frontmatter to prove normalize rewrites.
links:
---
# body
EOF
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm messy
  cp "$ROOT/records/failure-modes/messy.md" "$FIX/orig.md"
  # pass 1
  run bash "$GATE" --normalize --root "$ROOT" --paths "records/failure-modes/messy.md"
  [ "$status" -eq 0 ]
  # renamed to slug + canonical
  [ -f "$ROOT/records/failure-modes/tidy-slug.md" ]
  ! diff -q "$FIX/orig.md" "$ROOT/records/failure-modes/tidy-slug.md"   # NOT a no-op
  # first key line is id, links is {}, no trailing whitespace
  [ "$(sed -n '2p' "$ROOT/records/failure-modes/tidy-slug.md")" = "id: fm.tidy-slug" ]
  grep -q '^links: {}$' "$ROOT/records/failure-modes/tidy-slug.md"
  ! grep -nq '[[:space:]]$' "$ROOT/records/failure-modes/tidy-slug.md"
  # pass 2 is byte-identical
  cp "$ROOT/records/failure-modes/tidy-slug.md" "$FIX/pass1.md"
  run bash "$GATE" --normalize --root "$ROOT" --paths "records/failure-modes/tidy-slug.md"
  [ "$status" -eq 0 ]
  diff "$FIX/pass1.md" "$ROOT/records/failure-modes/tidy-slug.md"
}

# ---- AC5: structured reason and subject land in git history ----
@test "AC5: commit message carries subject and why/source/evidence trailers" {
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md .index" \
    --what "1 failure-mode" --why "the trigger" --source "session S lines 1-9" --evidence "turn evidence"
  [ "$status" -eq 0 ]
  local msg; msg="$(git -C "$ROOT" log -1 --format=%B)"
  [[ "$msg" == "records($(basename "$ROOT")): 1 failure-mode"* ]]
  [[ "$msg" == *"why: the trigger"* ]]
  [[ "$msg" == *"source: session S lines 1-9"* ]]
  [[ "$msg" == *"evidence: turn evidence"* ]]
}

# ---- AC6: per-store validate.sh is invoked and can veto ----
@test "AC6: per-store validate.sh vetoes (exit1), passes (exit0), and is optional (absent)" {
  mkdir -p "$ROOT/scripts"
  # exit 1 -> blocked even though baseline passes
  printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/scripts/validate.sh"; chmod +x "$ROOT/scripts/validate.sh"
  _fm "$ROOT/records/failure-modes/v.md" fm.v
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/v.md .index" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"per-store-validate"* ]]
  [ "$(_commit_count)" -eq "$before" ]
  # exit 0 -> proceeds
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/scripts/validate.sh"; chmod +x "$ROOT/scripts/validate.sh"
  _run_gate --root "$ROOT" --paths "records/failure-modes/v.md .index" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  [ "$(_commit_count)" -eq "$((before + 1))" ]
  # absent -> baseline-only still commits
  rm -rf "$ROOT/scripts"
  _fm "$ROOT/records/failure-modes/v2.md" fm.v2
  _run_gate --root "$ROOT" --paths "records/failure-modes/v2.md .index" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
}

# ---- AC7: one bad record aborts the batch; re-invoke with the clean one commits ----
@test "AC7: a leaking record in a batch aborts the whole root; re-invoke clean commits" {
  _fm "$ROOT/records/failure-modes/clean.md" fm.clean
  _fm "$ROOT/records/failure-modes/leaky.md" fm.leaky
  printf 'p: /Users/bob/x\n' >> "$ROOT/records/failure-modes/leaky.md"
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/clean.md records/failure-modes/leaky.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"leaky.md"* ]]
  [[ "$output" == *"re-invoke"* ]]
  [ "$(_commit_count)" -eq "$before" ]
  _run_gate --root "$ROOT" --paths "records/failure-modes/clean.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  [ "$(_commit_count)" -eq "$((before + 1))" ]
  git -C "$ROOT" show --stat HEAD | grep -q "clean.md"
}

# ---- AC8: langwatch namespace rule lives in the store validate.sh only ----
@test "AC8: bare-namespace id passes shared root but is vetoed by a langwatch validate.sh" {
  # shared root: no validate.sh, bare id commits
  _fm "$ROOT/records/failure-modes/bare.md" fm.bare
  _run_gate --root "$ROOT" --paths "records/failure-modes/bare.md .index" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  # langwatch root: validate.sh enforces the .langwatch. namespace
  local LW="$FIX/lw"; _init_root "$LW"
  mkdir -p "$LW/scripts"
  cat > "$LW/scripts/validate.sh" <<'EOF'
#!/usr/bin/env bash
rc=0
for f in "$@"; do
  id=$(grep -m1 '^id:' "$f" | sed 's/^id:[[:space:]]*//')
  case "$id" in *.langwatch.*) ;; *) echo "not langwatch-namespaced: $f ($id)" >&2; rc=1 ;; esac
done
exit $rc
EOF
  chmod +x "$LW/scripts/validate.sh"
  _fm "$LW/records/failure-modes/bare.md" fm.bare
  PROCEDURES_STATE_DIR="$FIX/state" COMMIT_RECORDS_NO_PUSH=1 run bash "$GATE" \
    --root "$LW" --paths "records/failure-modes/bare.md .index" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"per-store-validate"* ]]
}

# ---- AC9: size guard, boundary exact ----
@test "AC9: 32768 bytes passes, 32769 bytes is rejected" {
  # Build a canonical record (normalize is a no-op) then pad to an exact size.
  # _pad_to <path> <id> <target-bytes> — canonical record padded to N bytes.
  _pad_to() {  # <path> <id> <target-bytes>
    _fm "$1" "$2"
    local cur need; cur=$(wc -c < "$1" | tr -d '[:space:]'); need=$(( $3 - cur - 1 ))
    { head -c "$need" </dev/zero | tr '\0' x; printf '\n'; } >> "$1"
  }
  _pad_to "$ROOT/records/failure-modes/ok.md" fm.ok 32768
  [ "$(wc -c < "$ROOT/records/failure-modes/ok.md" | tr -d '[:space:]')" -eq 32768 ]
  _run_gate --root "$ROOT" --paths "records/failure-modes/ok.md .index" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  _pad_to "$ROOT/records/failure-modes/big.md" fm.big 32769
  [ "$(wc -c < "$ROOT/records/failure-modes/big.md" | tr -d '[:space:]')" -eq 32769 ]
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/big.md .index" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [size]"* ]]
  [[ "$output" == *"32768"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC13: required-section flag block path ----
@test "AC13: LINT_SECTIONS_REQUIRED=1 makes a missing section abort with a queue entry" {
  cat > "$ROOT/records/decisions/d.md" <<'EOF'
---
id: dec.d
kind: decision
date: 2026-09-05
keywords: [k]
links: {}
status: active
description: a decision missing its Chosen path section for the flag-block test.
---
# d
## Goal
g
## Outcome
o
EOF
  local before; before=$(_commit_count)
  LINT_SECTIONS_REQUIRED=1 COMMIT_RECORDS_NO_PUSH=1 run bash "$GATE" \
    --root "$ROOT" --paths "records/decisions/d.md .index" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [sections]"* ]]
  [ "$(_commit_count)" -eq "$before" ]
  grep -q "d.md" "$QUEUE"
}

# ---- AC14: rebuilt index lands in the record's own commit ----
@test "AC14: the single commit contains both the record and the .index" {
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  # --paths omits .index deliberately: the gate must add it internally.
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  local stat; stat="$(git -C "$ROOT" show --stat --format='' HEAD)"
  [[ "$stat" == *"records/failure-modes/rec.md"* ]]
  [[ "$stat" == *".index/"* ]]
  # no separate index-only commit, and nothing left unstaged
  [ -z "$(git -C "$ROOT" status --porcelain)" ]
}

# ---- AC15: push conflict -> rebase --abort, clean tree, queue, no force ----
@test "AC15: a push rejected with a non-fast-forwardable rebase aborts cleanly and queues" {
  _remote_fixture "records/failure-modes/contested.md" fm.contested
  _fm "$A/records/failure-modes/contested.md" fm.contested LOCAL
  # push NOT skipped here
  PROCEDURES_STATE_DIR="$FIX/state" run bash "$GATE" \
    --root "$A" --paths "records/failure-modes/contested.md .index" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [push]"* ]]
  [ -z "$(git -C "$A" status --porcelain)" ]              # tree clean
  [ ! -d "$A/.git/rebase-merge" ] && [ ! -d "$A/.git/rebase-apply" ]   # no rebase in progress
  git -C "$A" log -1 --format=%s | grep -q "records("      # local commit retained
  grep -q "check: push" "$QUEUE"                           # queued
}

# ---- AC16: duplicate id created by the merge (whole-root scan) ----
@test "AC16: a staged record colliding with one already on history is blocked" {
  _fm "$ROOT/records/failure-modes/existing.md" fm.dup
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm existing
  _fm "$ROOT/records/failure-modes/incoming.md" fm.dup   # collides with committed one
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/incoming.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate id"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC17: case-twin paths ----
@test "AC17: two paths differing only by case are blocked" {
  _fm "$ROOT/records/failure-modes/Rec.md" fm.Rec
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm cased
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [case-twin]"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC18: a record with no frontmatter block is blocked, not warned ----
@test "AC18: a fence-less record is rejected" {
  printf '# no frontmatter\n\njust text\n' > "$ROOT/records/failure-modes/nofence.md"
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/nofence.md .index" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [fence-block]"* ]]
  [ "$(_commit_count)" -eq "$before" ]
}

# ---- AC19: a non-record path in --paths is rejected before git add ----
@test "AC19: a non-record path in --paths is rejected before git add" {
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  printf 'token: xoxb-1-2\n' > "$ROOT/records/failure-modes/notes.txt"
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md records/failure-modes/notes.txt" \
    --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"records/failure-modes/notes.txt"* ]]
  [ "$(_commit_count)" -eq "$before" ]
  [ -z "$(git -C "$ROOT" diff --cached --name-only)" ]     # nothing staged
}

# ---- AC19 compat: legacy .index in --paths still commits and stages the index ----
@test "AC19: legacy --paths with .index still commits and includes .index/ in the commit" {
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md .index" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  local stat; stat="$(git -C "$ROOT" show --stat --format='' HEAD)"
  [[ "$stat" == *"records/failure-modes/rec.md"* ]]
  [[ "$stat" == *".index/"* ]]
}

# ---- AC20: metadata cap is a byte budget, not a character count ----
@test "AC20: commit metadata cap is measured in bytes, not characters" {
  _fm "$ROOT/records/failure-modes/rec.md" fm.rec
  # 1500 × the 2-byte UTF-8 char é = 3000 bytes > 2048. Build it from raw bytes
  # (\303\251) so the test does not depend on the runner locale.
  local why; why="$(printf '\303\251%.0s' $(seq 1 1500))"
  local before; before=$(_commit_count)
  _run_gate --root "$ROOT" --paths "records/failure-modes/rec.md" \
    --what x --why "$why" --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [metadata]"* ]]
  [ "$(_commit_count)" -eq "$before" ]
  # exactly 2048 ASCII bytes is within the cap and commits.
  _fm "$ROOT/records/failure-modes/ok.md" fm.ok
  local pad; pad="$(printf 'x%.0s' $(seq 1 2048))"
  _run_gate --root "$ROOT" --paths "records/failure-modes/ok.md" \
    --what x --why "$pad" --source s --evidence e
  [ "$status" -eq 0 ]
}

# ---- AC21: push retry — rebase imports an upstream DUPLICATE id and is blocked ----
@test "AC21: push retry — rebase imports an upstream duplicate id and is blocked" {
  _remote_fixture "records/failure-modes/remote.md" fm.same
  _fm "$A/records/failure-modes/local.md" fm.same LOCAL
  PROCEDURES_STATE_DIR="$FIX/state" run bash "$GATE" \
    --root "$A" --paths "records/failure-modes/local.md" --what x --why w --source s --evidence e
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCK [duplicate-id]"* ]]
  grep -q "check: duplicate-id" "$QUEUE"
  [ ! -d "$A/.git/rebase-merge" ] && [ ! -d "$A/.git/rebase-apply" ]   # no rebase in progress
}

# ---- AC22: push retry — rebase imports a distinct upstream record, reindexes, and pushes ----
@test "AC22: push retry — rebase imports a distinct upstream record, reindexes, and pushes" {
  _remote_fixture "records/failure-modes/remote.md" fm.remote
  _fm "$A/records/failure-modes/local.md" fm.local LOCAL
  PROCEDURES_STATE_DIR="$FIX/state" run bash "$GATE" \
    --root "$A" --paths "records/failure-modes/local.md" --what x --why w --source s --evidence e
  [ "$status" -eq 0 ]
  [[ "$output" == *"committed and pushed"* ]]
  [ "$(git -C "$A" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)" ]   # remote tip == local HEAD
  [ -z "$(git -C "$A" status --porcelain)" ]                                   # tree clean
  grep -q "fm.local" "$A/.index/map.tsv"
  grep -q "fm.remote" "$A/.index/map.tsv"
  git -C "$A" diff --quiet -- .index                                           # committed index == working copy
}
