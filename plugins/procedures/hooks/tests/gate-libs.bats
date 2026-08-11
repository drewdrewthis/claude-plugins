#!/usr/bin/env bats
# Tests for the gate libraries: turn-state, gate-audience, gate-allowlist.
#
# These are the shared units the three gates compose. Testing them directly
# means each gate's own suite only has to prove POLICY, not storage or parsing.
#
# Run: bats hooks/tests/gate-libs.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib"
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ts.XXXXXX")"
  SID="bats-$$-$BATS_TEST_NUMBER"
}

teardown() {
  rm -rf "$TURN_STATE_DIR" 2>/dev/null || true
}

# ---------- turn-state ----------

@test "turn-state: a fresh session has no turn started" {
  source "$LIB/turn-state.sh"
  run ts_turn_started "$SID"
  [ "$status" -ne 0 ]
}

@test "turn-state: reset stamps the turn marker" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  run ts_turn_started "$SID"
  [ "$status" -eq 0 ]
}

@test "turn-state: mark then is_marked" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  run ts_is_marked "$SID" how_do_i
  [ "$status" -ne 0 ]
  ts_mark "$SID" how_do_i
  run ts_is_marked "$SID" how_do_i
  [ "$status" -eq 0 ]
}

@test "turn-state: reset clears a key it does not enumerate" {
  # Regression: ts_reset hard-coded three keys, so am_i_done_asked survived
  # every turn and demoted am-i-done to once-per-SESSION.
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" am_i_done_asked
  ts_mark "$SID" some_future_key
  ts_reset "$SID"
  run ts_is_marked "$SID" am_i_done_asked; [ "$status" -ne 0 ]
  run ts_is_marked "$SID" some_future_key; [ "$status" -ne 0 ]
  # ...but the turn sentinel must survive, or every gate fails open.
  run ts_turn_started "$SID"; [ "$status" -eq 0 ]
}

@test "turn-state: reset clears flags from the previous turn" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" how_do_i
  ts_mark "$SID" am_i_done
  ts_reset "$SID"
  run ts_is_marked "$SID" how_do_i;  [ "$status" -ne 0 ]
  run ts_is_marked "$SID" am_i_done; [ "$status" -ne 0 ]
}

@test "turn-state: flags are independent (no lost update between keys)" {
  source "$LIB/turn-state.sh"
  ts_reset "$SID"
  ts_mark "$SID" how_do_i &
  ts_mark "$SID" am_i_done &
  wait
  run ts_is_marked "$SID" how_do_i;  [ "$status" -eq 0 ]
  run ts_is_marked "$SID" am_i_done; [ "$status" -eq 0 ]
}

@test "turn-state: session id is sanitised against traversal" {
  source "$LIB/turn-state.sh"
  run ts_session_id '{"session_id":"../../etc/passwd"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *".."* ]]
  [[ "$output" != *"/"* ]]
}

@test "turn-state: missing session id falls back to a stable bucket" {
  source "$LIB/turn-state.sh"
  run ts_session_id '{}'
  [ "$output" = "unknown" ]
}

# ---------- gate-audience ----------

@test "audience: a delegated subagent is never gated" {
  source "$LIB/gate-audience.sh"
  P='{"agent_id":"abc123"}'
  run ga_is_subagent "$P";   [ "$status" -eq 0 ]
  run ga_binds_main "$P";    [ "$status" -ne 0 ]
}

@test "audience: every non-subagent payload binds" {
  source "$LIB/gate-audience.sh"
  run ga_binds_main '{}'
  [ "$status" -eq 0 ]
  run ga_binds_main '{"agent_id":"abc"}'
  [ "$status" -ne 0 ]
}

# ---------- gate-allowlist ----------

@test "allowlist: Skill is always the compliance path" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Skill '{"tool_name":"Skill"}'
  [ "$status" -eq 0 ]
}

@test "allowlist: Agent is allowed so a delegating skill cannot deadlock" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Agent '{"tool_name":"Agent"}'
  [ "$status" -eq 0 ]
}

@test "allowlist: Read under references/procedures is allowed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Read '{"tool_input":{"file_path":"/home/u/.claude/references/procedures/x/PROCEDURE.md"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: traversal out of the procedures tree is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Read '{"tool_input":{"file_path":"/x/references/procedures/../../CLAUDE.md"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: read-only discovery Bash is allowed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"grep -r foo references/procedures/"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: destructive Bash merely MENTIONING the surface is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"rm -rf references/procedures/"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: an ordinary Edit is not the compliance path" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Edit '{"tool_input":{"file_path":"/tmp/x"}}'
  [ "$status" -ne 0 ]
}

# ---------- gate-allowlist: gate on ACT, not on LOOK (2026-08-09) ----------
#
# Six confirmed misfires on 2026-08-09: pure reads denied because the old
# allowlist demanded the command also NAME `references/procedures/`. Each
# shape below is one of them. The negatives right after prove the widening
# did not open a write path.

@test "allowlist: a read of ANY file is allowed, not just the procedures tree" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Read '{"tool_input":{"file_path":"/tmp/claude/tasks/btwvalrxw.output"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: Grep and Glob are looks" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Grep '{"tool_input":{"pattern":"foo","path":"/var/log"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Glob '{"tool_input":{"pattern":"**/*.sh"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: traversal in Glob pattern / Grep glob-path is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Glob '{"tool_input":{"pattern":"../../**/*.env"}}'
  [ "$status" -eq 1 ]
  run gal_is_compliance_path Grep '{"tool_input":{"pattern":"foo","glob":"../*.env"}}'
  [ "$status" -eq 1 ]
  run gal_is_compliance_path Grep '{"tool_input":{"pattern":"foo","path":"../secrets"}}'
  [ "$status" -eq 1 ]
}

@test "allowlist: '..' inside a Grep REGEX is not traversal" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Grep '{"tool_input":{"pattern":"a..b.*end","path":"/var/log"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: tmux capture-pane piped through grep and tail is a look" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"tmux capture-pane -t amzcart2 -p -S -60 | grep -v boring | tail -40"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: a plain file read through Bash is a look" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat /home/u/notes/2026-08-09.md"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: input redirection reads, so wc -l < file is a look" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"wc -l < decisions.jsonl"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"tail -4 decisions.jsonl | jq -r .id"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: read-only subcommands of multiplexers are looks" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git status --short"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"systemctl --user status claude-agents"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"docker ps -a"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: a writing subcommand of an allowed multiplexer is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git commit -m x"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"tmux send-keys -t agent hi Enter"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"docker exec c rm -rf /"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"systemctl --user restart claude-agents"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: redirection to a file is a write, however read-only the stages" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"grep foo bar > out"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat x >> y"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: a pipeline is judged whole — tee at the end is still a write" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat x | tee y"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat x | xargs rm"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: command substitution reaching a mutator is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"echo $(rm -rf /tmp/x)"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat `rm -rf /tmp/x`"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: a chained verification sweep is a look, separators and all" {
  source "$LIB/gate-allowlist.sh"
  # Verbatim from the 2026-08-09 misfire set. Every segment reads; the command
  # was the disconfirming check on a correction just issued, so denying it
  # taxed the verification discipline the codex mandates.
  cmd='echo $CLAUDE_CODE_SESSION_ID; cd /home/admin/.claude && git rev-parse --short HEAD && git branch --show-current && git status --porcelain | wc -l; git worktree list; git log --oneline -1 main; git show --stat main'
  run gal_is_compliance_path Bash "$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')"
  [ "$status" -eq 0 ]
}

@test "allowlist: a listing git subcommand reads, an operand makes it write" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git worktree list"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git worktree add ../x main"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git branch -D main"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git tag v1"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git stash"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: discarding output is not writing" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ls /nope 2>/dev/null | wc -l"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: sequencing and backgrounding cannot smuggle a second command" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ls; rm -rf /tmp/x"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ls && rm -rf /tmp/x"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ls || rm -rf /tmp/x"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"rm -rf /tmp/x &"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: sed edits in place but reads with -n" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"sed -n 1,20p /etc/hosts"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"sed -i s/a/b/ /etc/hosts"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: find is a reader until an action primary turns it into a writer" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"find /var/log -name *.log"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"find /var/log -name *.log -delete"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: an interpreter is unjudgeable, so it fails closed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"python3 -c import json"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"bash script.sh"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: an env-assignment prefix hides the real command, so it is refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"FOO=1 cat /etc/hosts"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: an unknown command is not assumed harmless" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"frobnicate --all"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":""}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: git options that hand execution to an external program are refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git grep -Otouch foo"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git grep --open-files-in-pager=touch foo"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git diff --ext-diff"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git --config-env=core.pager=EVIL log"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"git grep foo"}}'
  [ "$status" -eq 0 ]
}

@test "allowlist: write-capable modes of listed readers are refused" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"sort -o out in"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"uniq in out"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"xxd -r in out"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"yq -i .a=1 f.yml"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"date -s 20260101"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ip link set eth0 down"}}'
  [ "$status" -ne 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"ip addr"}}'
  [ "$status" -ne 0 ]
}

@test "allowlist: the read-only modes of those readers stay allowed" {
  source "$LIB/gate-allowlist.sh"
  run gal_is_compliance_path Bash '{"tool_input":{"command":"sort in"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"uniq -c in"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"cat f.yml | yq .a"}}'
  [ "$status" -eq 0 ]
  run gal_is_compliance_path Bash '{"tool_input":{"command":"date -u"}}'
  [ "$status" -eq 0 ]
}
