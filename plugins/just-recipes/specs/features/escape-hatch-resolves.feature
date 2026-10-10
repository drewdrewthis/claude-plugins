# Coverage map for claude-plugins#223 — the enforce-just hook names an escape
# hatch only when `just --summary` shows a recipe that really is `wrap`. Not
# executable: each Scenario carries a "# proves:" comment naming the bats test
# that proves it.

Feature: The hook advice resolves at run time and never names a path that does not exist
  Today the hook prints a fixed `just --justfile "$HOME/.claude/just/justfile" ... wrap`
  line. With no such file the command fails. After the fix the hook probes with
  `just --summary` (project first, then the global file) and names only a hatch
  that resolves. With none it names no hatch and no global path. It always exits 0.

  # proves: hooks/tests/enforce-just.bats "no hatch: no project justfile and no global file -> the nudge names no global path"
  Scenario: No global file, the nudge names no global path
    Given no project justfile and no global file
    When a non-allowlisted command runs
    Then the nudge holds no --justfile, no .claude/just/justfile and no just --list

  # proves: hooks/tests/enforce-just.bats "no hatch: no project justfile and no global file -> the nudge names no wrap"
  Scenario: No global file, the nudge names no wrap
    Given no project justfile and no global file
    When a non-allowlisted command runs
    Then the nudge does not contain wrap

  # proves: hooks/tests/enforce-just.bats "no hatch: strict with no global file -> the reason names no global path"
  Scenario: No global file, the strict reason names no global path
    Given strict mode, no project justfile and no global file
    When a non-allowlisted command runs
    Then the reason holds no --justfile, no .claude/just/justfile and no just --list

  # proves: hooks/tests/enforce-just.bats "no hatch: a dangling-symlink global file -> the nudge names no global path"
  Scenario: A dangling symlink counts as absent for paths
    Given the global path is a symlink to a missing file
    When a non-allowlisted command runs
    Then the nudge holds no global path

  # proves: hooks/tests/enforce-just.bats "no hatch: a dangling-symlink global file -> the nudge names no wrap"
  Scenario: A dangling symlink counts as absent for wrap
    Given the global path is a symlink to a missing file
    When a non-allowlisted command runs
    Then the nudge does not contain wrap

  # proves: hooks/tests/enforce-just.bats "global hatch: a global wrap recipe and an empty project dir -> the global form is named"
  Scenario: A global wrap recipe is named with the global form
    Given a global justfile with a wrap recipe and a project dir with no justfile
    When a non-allowlisted command runs
    Then the text holds just --justfile "<global path>" -d . wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "global hatch: JUST_GLOBAL_JUSTFILE with a space in the path -> that path is named, quoted"
  Scenario: The override path is named, quoted
    Given JUST_GLOBAL_JUSTFILE points at a file with a wrap recipe under a path with a space
    When a non-allowlisted command runs
    Then the text names that quoted path in the global form

  # proves: hooks/tests/enforce-just.bats "global hatch: a project justfile without wrap and a global with wrap -> the global form is named"
  Scenario: A project justfile without wrap falls through to the global wrap
    Given a project justfile with no wrap recipe and a global justfile with one
    When a non-allowlisted command runs
    Then the text holds the global form

  # proves: hooks/tests/enforce-just.bats "project hatch: a project wrap recipe -> 'just wrap' is named"
  Scenario: A project wrap recipe is named
    Given a project justfile with a wrap recipe
    When a non-allowlisted command runs
    Then the text holds just wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "project hatch: project and global both have wrap -> the global form is not named"
  Scenario: The project wins over the global
    Given both the project and the global justfile have a wrap recipe
    When a non-allowlisted command runs
    Then the text holds no --justfile

  # proves: hooks/tests/enforce-just.bats "project hatch: a module recipe tools::wrap -> 'just tools::wrap' is named"
  Scenario: A module wrap recipe is named with its module
    Given the project summary lists tools::wrap
    When a non-allowlisted command runs
    Then the text holds just tools::wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "project hatch: a bare wrap beats a module tools::wrap"
  Scenario: A bare wrap beats a module wrap
    Given the project summary lists both wrap and tools::wrap
    When a non-allowlisted command runs
    Then the text holds just wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "near miss: global recipes wrap-report, unwrap and tools::rewrap -> no wrap form"
  Scenario: Global near misses do not count as wrap
    Given the global summary lists wrap-report, unwrap and tools::rewrap
    When a non-allowlisted command runs
    Then the text holds no wrap "<your command>" form

  # proves: hooks/tests/enforce-just.bats "near miss: project recipes wrap-report, unwrap and tools::rewrap -> no wrap form"
  Scenario: Project near misses do not count as wrap
    Given the project summary lists wrap-report, unwrap and tools::rewrap
    When a non-allowlisted command runs
    Then the text holds no wrap "<your command>" form

  # proves: hooks/tests/enforce-just.bats "broken justfiles: every just probe fails -> no wrap form"
  Scenario: Broken justfiles give no hatch
    Given every just call fails
    When a non-allowlisted command runs
    Then the text holds no wrap "<your command>" form

  # proves: hooks/tests/enforce-just.bats "broken justfiles: every just probe fails -> the hook exits 0"
  Scenario: Broken justfiles never fail the hook
    Given every just call fails
    When a non-allowlisted command runs
    Then the hook exits 0

  # proves: hooks/tests/enforce-just.bats "broken project justfile and a good global with wrap -> the global form is named"
  Scenario: A broken project justfile falls through to a good global
    Given the project summary fails and the global summary lists wrap
    When a non-allowlisted command runs
    Then the text holds the global form

  # proves: hooks/tests/enforce-just.bats "list hint: a resolving project justfile -> 'just --list' is named"
  Scenario: The list hint names the project listing
    Given a project justfile that lists
    When a non-allowlisted command runs
    Then the text holds just --list

  # proves: hooks/tests/enforce-just.bats "list hint: only the global file resolves -> 'just --justfile <path> --list' is named"
  Scenario: The list hint names the global listing
    Given only the global justfile lists
    When a non-allowlisted command runs
    Then the text holds just --justfile "<global path>" --list

  # proves: hooks/tests/enforce-just.bats "list hint: nothing resolves -> 'just --list' is not named"
  Scenario: No listing, no list hint
    Given neither a project nor a global justfile
    When a non-allowlisted command runs
    Then the text does not hold just --list

  # proves: hooks/tests/enforce-just.bats "strict with no hatch -> deny"
  Scenario: Strict with no hatch still denies
    Given strict mode and no wrap recipe anywhere
    When a non-allowlisted command runs
    Then the decision is deny

  # proves: hooks/tests/enforce-just.bats "strict with no hatch -> the reason names JUST_RECIPES_ENFORCE=off"
  Scenario: The strict reason names the kill switch
    Given strict mode and no wrap recipe anywhere
    When a non-allowlisted command runs
    Then the reason holds JUST_RECIPES_ENFORCE=off

  # proves: hooks/tests/enforce-just.bats "strict with no hatch -> the reason names no wrap command"
  Scenario: The strict reason names no wrap command
    Given strict mode and no wrap recipe anywhere
    When a non-allowlisted command runs
    Then the reason holds no wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "strict deny reason carries the resolved escape hatch"
  Scenario: The strict reason carries the resolved hatch
    Given strict mode and a global wrap recipe
    When a non-allowlisted command runs
    Then the reason holds the global form

  # proves: hooks/tests/enforce-just.bats "cost: a non-allowlisted command runs at most 4 just invocations"
  Scenario: A non-allowlisted command runs at most 4 just calls
    Given a counting just and both justfiles present
    When a non-allowlisted command runs
    Then at most 4 just calls are logged

  # proves: hooks/tests/enforce-just.bats "cost: a non-allowlisted command runs at most 2 just --summary"
  Scenario: A non-allowlisted command runs at most 2 summary calls
    Given a counting just and both justfiles present
    When a non-allowlisted command runs
    Then at most 2 logged calls are --summary

  # proves: hooks/tests/enforce-just.bats "cost: an allowlisted command runs no just at all"
  Scenario: An allowlisted command runs no just
    Given a counting just
    When ls runs
    Then no just call is logged

  # AC 9: the dead path is gone from the skill and the hook.
  # evidence: grep -nF 'Always-resolving' SKILL.md returns 0 lines, and the sentence "The hook names the wrap command only when a wrap recipe resolves; when it names none, no wrap recipe is installed." appears once
  Scenario: The fixed escape-hatch text is removed
    Given the skill file
    When it is searched for the old claim
    Then nothing is found and the new sentence appears once

  # AC 10: the change is named as a fix.
  # evidence: the PR title is fix(just-recipes): ..., which triggers the release-please patch bump (no manual plugin.json edit)
  Scenario: The PR is titled as a fix
    Given the pull request
    When its title is read
    Then it starts with fix(just-recipes):

  # AC 11: the fix reaches the box after the release is merged (owner: box operator).
  # evidence: installed plugin version quoted and grep -c 'always resolves' on the cached hook is 0; just --version quoted from a ship worker session and the assistant session; one live additionalContext quoted with every path passing test -e
  Scenario: The released hook runs on the box
    Given the release is merged and installed on the box
    When a non-allowlisted Bash call runs
    Then the advice names only paths that exist

# --- AC Coverage Map ---
# AC 1  no hatch, no global path when nothing resolves   -> scenarios 1-5
# AC 2  global wrap named with the resolved path         -> scenarios 6-8
# AC 3  project wrap, project wins, module form          -> scenarios 9-12
# AC 4  near misses, broken files, exit 0, fall-through  -> scenarios 13-17
# AC 5  list hint (project, global only, neither)        -> scenarios 18-20
# AC 6  strict with no hatch still denies                -> scenarios 21-23
# AC 7  strict reason carries the resolved hatch         -> scenario 24
# AC 8  probe cost bounded                               -> scenarios 25-27
# AC 9  old fixed text gone                              -> scenario 28 (grep)
# AC 10 PR title                                         -> scenario 29 (PR title)
# AC 11 box run after merge                              -> scenario 30 (box run)
