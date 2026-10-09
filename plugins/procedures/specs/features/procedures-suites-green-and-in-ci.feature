# Coverage map for claude-plugins#210 — four procedures bats suites were red on
# main after #144 turned three gates default-off, and no CI ran them. Not
# executable: each Scenario carries a "# proves:" comment naming the bats test,
# command or CI artifact that proves it. Paths are under plugins/procedures/.

Feature: The procedures bats suites are green, hermetic, and run in CI
  Every suite states the post-#144 contract (how_do_i_gate, am_i_done_gate and
  query_shape_guard are default-off), ignores the caller's environment, never
  touches the real home or the checkout, can fail when the code under test is
  broken, and runs on every pull request and push to main on Linux and macOS.

  # proves: command `env -u <every PROCEDURES_ENABLE_* and CLAUDE_PLUGIN_OPTION_ENABLE_*> bats hooks/tests/{gate-escape,gates,query-shape-guard,how-do-i,gate-failopen}.bats` as non-root; quoted exit code and plan line per suite (24, 41, 24, 45, 29 minimum)
  @integration
  Scenario: Each suite is green with a clean environment
    Given no PROCEDURES_ENABLE_* or CLAUDE_PLUGIN_OPTION_ENABLE_* variable is set
    When the five suites run as a non-root user
    Then each exits 0 with no "not ok" and no skip
    And each plan line is at least its count on main

  # proves: hooks/tests/gates.bats "root cause orchard-codex#210: this suite does not leak a fail-open record into a bystander's real HOME" (setup() calls clear_gate_switches), plus command form: the five suites run with the three gate switches true, then false with the option twins, then the twins true, then PROCEDURES_ENABLE_<KEY>=false for FRONTMATTER_CHECK, NUDGE, LIBRARIAN, EVOLVE_SWEEP
  @integration
  Scenario: Each suite ignores the caller's gate switches
    Given the caller exports gate switches in any of the four AC2 combinations
    When the five suites run
    Then each exits 0 with the same counts as the clean run

  # proves: hooks/tests/gates.bats "how-do-i-gate: unarmed is silent and records nothing, armed denies the same payload" (passes only because setup() arms and pins the logs)
  @integration
  Scenario: A suite's own setup decides whether a gate is armed
    Given the caller's environment arms or releases a gate
    When a gate test runs
    Then the gate state is the one setup() or the test chose, not the caller's

  # proves: hooks/tests/how-do-i.bats setup() (exports KNOWLEDGE_HOME, CLAUDE_CONFIG_DIR and CODEX_ROOT as temp dirs) via "a roots.stamp recording different roots than CODEX_ROOT forces a rebuild" and "an up-to-date index with a matching roots.stamp and no newer records is reused, not rebuilt"; command form: run how-do-i.bats on a box with a git repo under ~/.knowledge/modules/, `stat` the real .index/index.txt files before and after, and again with KNOWLEDGE_HOME and CODEX_ROOT preset
  @integration
  Scenario: how-do-i.bats ignores the real knowledge modules
    Given the real ~/.knowledge/modules holds a git repo with an index
    When how-do-i.bats runs
    Then it exits 0
    And no real index.txt mtime changes
    And it still exits 0 when KNOWLEDGE_HOME and CODEX_ROOT are preset elsewhere

  # proves: command `stat` on ~/.claude/gate-escape.jsonl and ~/.claude/gate-failopen.jsonl before and after the five suites; hooks/tests/gates.bats "root cause orchard-codex#210: this suite does not leak a fail-open record into a bystander's real HOME"
  @integration
  Scenario: The suites leave the real gate logs alone
    Given the real escape and fail-open logs have a recorded size and mtime
    When the five suites run
    Then the size and mtime of both logs are unchanged, or both are absent

  # proves: mutant in a throwaway copy: gal_is_compliance_path and ts_is_marked always return 1; hooks/tests/gates.bats fails "record: the legacy {tool,input} payload shape still marks the flag", "record: namespaced procedures:how-do-i stamps the how_do_i marker", "record: namespaced procedures:am-i-done stamps its marker", "how-do-i-gate: allows once Skill(how-do-i) has run", "how-do-i-gate: allows a compliance Agent dispatch while outstanding (no deadlock)", "how-do-i-gate: allows reading a procedure while outstanding", "how-do-i-gate: WebFetch is allowed while the gate is armed", "how-do-i-gate: BOTH the bare and the plugin-scoped invocation satisfy it", "am-i-done-gate: BOTH the bare and the plugin-scoped invocation satisfy it" (nine, positions 2,4,5,13,14,16,17,36,37)
  @integration
  Scenario: gates.bats fails when the armed allow logic is broken
    Given gates.bats arms both gates in setup()
    When the allowlist and marker checks are mutated to always return 1
    Then at least nine tests that pass on the unmodified copy fail

  # proves: mutant in a throwaway copy: query-shape-guard.sh denies non-reviewers; hooks/tests/query-shape-guard.bats fails "a session with no fork identity is released untouched" and "another plugin's fork (delegation:coder) is released untouched"
  @integration
  Scenario: query-shape-guard.bats fails when the guard denies everyone
    Given query-shape-guard.bats arms the guard
    When the guard is mutated to deny non-reviewers
    Then the no-fork-identity and other-plugin-fork tests fail

  # proves: hooks/tests/gates.bats "how-do-i-gate: unarmed is silent and records nothing, armed denies the same payload" and "am-i-done-gate: unarmed is silent and records nothing, armed blocks the same payload"; hooks/tests/query-shape-guard.bats "an unarmed guard releases silently and records nothing; arming denies and records armed_by"; hooks/tests/gate-escape.bats "how-do-i-gate: silent when unarmed, denies when armed, silent again when switched off" and "am-i-done-gate: silent when unarmed, blocks when armed, silent again when switched off"
  @integration
  Scenario: Each gate suite has an unarmed negative control with an armed premise
    Given a payload the armed gate denies and records
    When the same payload goes to the unarmed gate
    Then the output, escape log and fail-open log are empty
    And leaving the gate armed makes the test fail

  # proves: command `grep -niE 'armed by default|on by default|defaulting to on|default on|defaults to on' hooks/tests/{gate-escape,gates,query-shape-guard,how-do-i,gate-failopen}.bats`; the only hit that stays is hooks/tests/gate-escape.bats "enforce-frontmatter: armed by default, released by its own switch" (truthfully default-on)
  @unit
  Scenario: No suite calls a default-off gate armed by default
    Given the five suites
    When they are searched for "armed by default" style wording
    Then every remaining hit is about a default-on gate

  # proves: hooks/tests/gate-escape.bats "plugin.json declares one boolean switch per gate, with polarity matching the lib" (EVOLVE_SWEEP exemption comment carries the follow-up issue URL https://github.com/drewdrewthis/claude-plugins/issues/220); mutant runs: flip enable_nudge default to false in a copy, flip enable_how_do_i_gate to true in a copy
  @unit
  Scenario: The manifest default must match the lib polarity
    Given plugin.json declares a default per switch
    When one default disagrees with the lib, other than EVOLVE_SWEEP
    Then the polarity test fails

  # proves: hooks/tests/gate-failopen.bats "negative control: an unarmed how-do-i-gate on a degraded path records nothing and does not deny" and "negative control: an unarmed am-i-done-gate on a degraded path records nothing and does not block"
  @integration
  Scenario: Unarmed gates on a degraded path record nothing
    Given a degraded path such as an unresolvable skill
    When an unarmed gate runs
    Then it records nothing and neither denies nor blocks

  # proves: hooks/tests/gate-failopen.bats "G5 bootstrap hole: am-i-done-gate fails safely when hooks/lib/gate-failopen.sh is itself unreadable", "G5 bootstrap hole: how-do-i-gate fails safely when hooks/lib/gate-failopen.sh is itself unreadable", "case 4b: how-do-i-gate records lib-unreadable:turn-state instead of releasing silently" (unreadable_lib() chmods a per-test copy and skips as root); command `grep -n chmod hooks/tests/gate-failopen.bats`; command: five rounds of two concurrent `bats hooks/tests/gate-failopen.bats` in one checkout, all exit 0, `stat` of hooks/lib/*.sh identical before and after
  @integration
  Scenario: The unreadable-lib tests never lock a file in the checkout
    Given two bats runs of gate-failopen.bats in one checkout
    When they run at the same time for five rounds
    Then every run exits 0
    And the real hooks/lib modes are identical before and after
    And as root the chmod-000 tests skip with a message that names root

  # proves: file .github/workflows/procedures-tests.yml (glob over hooks/tests/*.bats and scripts/lib/tests/*.bats; matrix ubuntu-latest and macos-latest; pull_request paths filter plus push to main with no filter) and its run on PR https://github.com/drewdrewthis/claude-plugins/pull/221 (both legs success, per-leg total equals `bats --count`)
  @integration
  Scenario: CI runs every procedures suite on both platforms
    Given a pull request touching plugins/procedures or the workflow
    When procedures-tests runs
    Then ubuntu-latest and macos-latest each run every suite found by glob
    And both conclude success with no "not ok"

  # proves: the failing workflow run linked in the body of PR https://github.com/drewdrewthis/claude-plugins/pull/221 (a throwaway failing @test under hooks/tests/, reverted afterwards); no run URL is repeated here
  @integration
  Scenario: CI goes red when a suite fails
    Given a throwaway commit adds one failing @test under hooks/tests/
    When procedures-tests runs
    Then both legs conclude failure and the log names that file

  # proves: command `git diff --stat origin/main...HEAD` (only hooks/tests/*.bats, scripts/lib/tests/*.bats, specs/features/*.feature, the workflow, and scripts/commit-records.sh); the other 15 hooks/tests suites and 3 scripts/lib/tests suites exit 0; follow-up issue https://github.com/drewdrewthis/claude-plugins/issues/220 names the four production findings and gate-escape.bats test 22 (now "an unreadable escape lib makes every gate deny, even with its switch set to false")
  @integration
  Scenario: The change stays inside tests, CI and one guarded production line
    Given the branch diff against origin/main
    When the files touched are listed
    Then only the allowed paths appear
    And the follow-up issue records the four production findings

  # proves: hooks/tests/gate-escape.bats, each fails under its one-line mutant in a throwaway copy and passes unmodified: "escape: false and 0 release a default-on gate" (mutant: ge__off no longer accepts 0); "escape: the lib needs no external binary, recording included (PATH-empty safe)" (mutant: drop `|| echo unknown` in ge__record); "an explicit false on a gate is NOT recorded as a fail-open, even on a degraded path" (mutant: ge_release_or_failopen no longer asks the switch); "a switch is recorded only when the gate would otherwise have fired" (mutant: how-do-i-gate `ga_binds_main ... || exit 0` becomes `|| true`)
  @integration
  Scenario: The four formerly weak gate-escape tests fail under a one-line mutant
    Given a one-line mutant of gate-escape.sh or a gate script in a throwaway copy
    When gate-escape.bats runs
    Then the matching rewritten test fails and passes on the unmodified copy

  # proves: mutant in a throwaway copy: remove the HOME and GATE_FAILOPEN_LOG exports from gates.bats setup(); hooks/tests/gates.bats "root cause orchard-codex#210: this suite does not leak a fail-open record into a bystander's real HOME" fails
  @integration
  Scenario: The gates.bats leak guard fails without its setup exports
    Given gates.bats setup() pins HOME and GATE_FAILOPEN_LOG
    When those two exports are removed in a copy
    Then the leak-guard test fails

  # proves: hooks/tests/commit-records.bats "AC26: a store that gitignores .index/ still commits the record (index left local)"; command `PATH=<git 2.55 dir>:$PATH bats hooks/tests/commit-records.bats` gives 61 tests, 0 not ok, and the same test fails on the unfixed scripts/commit-records.sh; also green on git 2.39 and on both CI legs (git 2.55)
  @integration
  Scenario: A store that gitignores .index still commits under git 2.55
    Given a store whose .gitignore excludes .index/ and tracks nothing under it
    When commit-records.sh commits a record with git 2.55 first on PATH
    Then the commit succeeds and the index stays local

  # proves: hooks/tests/commit-records.bats "AC26: an ignored .index with nothing tracked never reaches git add -u (newer git exits 128 on it)" (a git shim first on PATH exits 128 with git 2.55's message for `add -u -- .index` when nothing under .index is tracked, so it holds on any git version); fails with the ls-files guard reverted in a throwaway copy, passes with it
  @integration
  Scenario: The .index restage is guarded on tracked files, on any git version
    Given a store that gitignores .index/ with nothing tracked under it
    And a git that exits 128 for `add -u -- .index` when nothing is tracked
    When commit-records.sh commits a record
    Then the commit succeeds

# --- AC Coverage Map ---
# AC1  -> Each suite is green with a clean environment
# AC2  -> Each suite ignores the caller's gate switches; A suite's own setup decides whether a gate is armed
# AC3  -> how-do-i.bats ignores the real knowledge modules
# AC4  -> gates.bats fails when the armed allow logic is broken; query-shape-guard.bats fails when the guard denies everyone
# AC5  -> Each gate suite has an unarmed negative control with an armed premise
# AC6  -> No suite calls a default-off gate armed by default
# AC7  -> The manifest default must match the lib polarity
# AC8  -> Unarmed gates on a degraded path record nothing; The unreadable-lib tests never lock a file in the checkout
# AC9  -> CI runs every procedures suite on both platforms
# AC10 -> The change stays inside tests, CI and one guarded production line
# AC11 -> CI goes red when a suite fails (proof: failing run linked in the body of PR #221)
# AC12 -> The suites leave the real gate logs alone
# AC13 -> The four formerly weak gate-escape tests fail under a one-line mutant; The gates.bats leak guard fails without its setup exports
# AC14 -> A store that gitignores .index still commits under git 2.55; The .index restage is guarded on tracked files, on any git version
