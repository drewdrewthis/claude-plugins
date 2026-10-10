# Coverage map for claude-plugins#223 — the enforce-just hook names an escape
# hatch only when `just --summary` shows a recipe that really is `wrap`. Not
# executable: each Scenario carries a "# proves:" comment naming the bats test
# that proves it.

Feature: The hook advice resolves at run time and never names a path that does not exist
  The hook probes with `just --summary`: the project recipe exactly `wrap` first,
  then the global library recipe exactly `wrap`, matched as a whole token. A
  module `wrap` is never named, because a mounted module recipe runs in the
  module's directory, not the caller's, unless it has [no-cd]. With no hatch the
  hook names no hatch and no global path. A global path in any printed command is
  shell-quoted (printf %q). It always exits 0.

  # proves: hooks/tests/enforce-just.bats "no hatch: no project justfile and no global file -> no global path, no wrap"
  Scenario: No global file, no hatch and no global path
    Given no project justfile and no global file
    When a non-allowlisted command runs
    Then the text holds no --justfile, no .claude/just/justfile, no just --list, no <your command>, no Escape hatch: and no wrap

  # proves: hooks/tests/enforce-just.bats "no hatch: strict with no global file -> the reason names no global path"
  Scenario: No global file, the strict reason names no global path
    Given strict mode, no project justfile and no global file
    When a non-allowlisted command runs
    Then the reason holds no --justfile, no .claude/just/justfile and no just --list

  # proves: hooks/tests/enforce-just.bats "no hatch: a dangling-symlink global file -> no global path, no wrap"
  Scenario: A dangling symlink counts as absent
    Given the global path is a symlink to a missing file
    When a non-allowlisted command runs
    Then the text holds no global path, no hatch and no wrap

  # proves: hooks/tests/enforce-just.bats "global hatch: a global wrap recipe and an empty project dir -> the global form is named"
  Scenario: A global wrap recipe is named with the global form
    Given a global justfile with a wrap recipe and a project dir with no justfile
    When a non-allowlisted command runs
    Then the text holds just --justfile <global path> -d . wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "global hatch: JUST_GLOBAL_JUSTFILE with a space in the path -> that path is named, quoted"
  Scenario: The override path is named, shell-quoted
    Given JUST_GLOBAL_JUSTFILE points at a file with a wrap recipe under a path with a space
    When a non-allowlisted command runs
    Then the text names that path in printf %q form in the global form

  # proves: hooks/tests/enforce-just.bats "global hatch: JUST_GLOBAL_JUSTFILE with a dollar and a quote in the path -> the %q form is named"
  Scenario: A path with a dollar and a quote is shell-quoted
    Given JUST_GLOBAL_JUSTFILE points at a wrap library under a path with a $ and a "
    When a non-allowlisted command runs
    Then the hatch and the list hint hold the printf %q form of the path

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

  # proves: hooks/tests/enforce-just.bats "project hatch: a module recipe tools::wrap is never named"
  Scenario: A module wrap recipe is never named
    Given the project summary lists tools::wrap and no bare wrap, and no global wrap
    When a non-allowlisted command runs
    Then the text holds no <your command> and no Escape hatch:

  # proves: hooks/tests/enforce-just.bats "project hatch: a bare wrap beats a module tools::wrap"
  Scenario: A bare wrap beats a module wrap
    Given the project summary lists both tools::wrap and wrap
    When a non-allowlisted command runs
    Then the text holds just wrap "<your command>"

  # proves: hooks/tests/enforce-just.bats "near miss: global recipes wrap-report, unwrap and tools::rewrap -> no hatch"
  Scenario: Global near misses do not count as wrap
    Given the global summary lists wrap-report, unwrap and tools::rewrap
    When a non-allowlisted command runs
    Then the text holds no <your command> and no Escape hatch:

  # proves: hooks/tests/enforce-just.bats "near miss: project recipes wrap-report, unwrap and tools::rewrap -> no hatch"
  Scenario: Project near misses do not count as wrap
    Given the project summary lists wrap-report, unwrap and tools::rewrap
    When a non-allowlisted command runs
    Then the text holds no <your command> and no Escape hatch:

  # proves: hooks/tests/enforce-just.bats "broken justfiles: every just probe fails -> no hatch"
  Scenario: Broken justfiles give no hatch
    Given every just call fails
    When a non-allowlisted command runs
    Then the text holds no <your command> and no Escape hatch:

  # proves: hooks/tests/enforce-just.bats "broken justfiles: every just probe fails -> the hook exits 0"
  Scenario: Broken justfiles never fail the hook
    Given every just call fails
    When a non-allowlisted command runs
    Then the hook exits 0

  # proves: hooks/tests/enforce-just.bats "broken project justfile and a good global with wrap -> the global form is named"
  Scenario: A broken project justfile falls through to a good global
    Given the project summary and list fail and the global summary lists wrap
    When a non-allowlisted command runs
    Then the text holds the global form

  # proves: hooks/tests/enforce-just.bats "project list works but project summary fails, global has wrap -> the global form is named"
  Scenario: A failing project summary falls through to the global
    Given the project list works, the project summary fails and the global summary lists wrap
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
    Then the text holds just --justfile <global path> --list

  # proves: hooks/tests/enforce-just.bats "list hint: nothing resolves -> 'just --list' is not named"
  Scenario: No listing, no list hint
    Given neither a project nor a global justfile
    When a non-allowlisted command runs
    Then the text does not hold just --list

  # proves: hooks/tests/enforce-just.bats "strict with no hatch -> deny, and the reason names JUST_RECIPES_ENFORCE=off"
  Scenario: Strict with no hatch still denies and names the kill switch
    Given strict mode and no wrap recipe anywhere
    When a non-allowlisted command runs
    Then the decision is deny and the reason holds JUST_RECIPES_ENFORCE=off

  # proves: hooks/tests/enforce-just.bats "strict with no hatch -> the reason names no hatch command"
  Scenario: The strict reason names no hatch command
    Given strict mode and no wrap recipe anywhere
    When a non-allowlisted command runs
    Then the reason holds no <your command> and no Escape hatch:

  # proves: hooks/tests/enforce-just.bats "strict deny reason carries the resolved escape hatch"
  Scenario: The strict reason carries the resolved hatch
    Given strict mode and a global wrap recipe
    When a non-allowlisted command runs
    Then the reason holds the global form

  # proves: hooks/tests/enforce-just.bats "cost: a non-allowlisted command runs 1-4 just calls, of which 1-2 are --summary"
  Scenario: A non-allowlisted command runs 1-4 just calls, 1-2 of them --summary
    Given a counting just and both justfiles present
    When ls runs
    Then 1 to 4 just calls are logged and 1 to 2 of them are --summary

  # proves: hooks/tests/enforce-just.bats "cost: no project justfile and a global file runs at most 4 just calls"
  Scenario: The worst case stays within 4 just calls
    Given a counting just, no project justfile and a global file
    When a non-allowlisted command runs
    Then 1 to 4 just calls are logged

  # proves: hooks/tests/enforce-just.bats "cost: an allowlisted command runs no just at all"
  Scenario: An allowlisted command runs no just
    Given a counting just
    When ls runs
    Then no just call is logged

  # AC 9: the dead path is gone from the skill and the hook.
  # evidence: grep -nF 'Always-resolving' SKILL.md returns 0 lines, and the sentence "The hook names the wrap command only when a wrap recipe resolves; when it names none, no usable wrap recipe resolved." appears once
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
# AC 1  no hatch, no global path when nothing resolves             -> scenarios 1-3
# AC 2  global wrap named, shell-quoted, with the resolved path    -> scenarios 4-7
# AC 3  project wrap only, project wins, module wrap never named   -> scenarios 8-11
# AC 4  near misses, broken files, exit 0, fall-through            -> scenarios 12-17
# AC 5  list hint (project, global only, neither)                  -> scenarios 18-20
# AC 6  strict with no hatch still denies                          -> scenarios 21-22
# AC 7  strict reason carries the resolved hatch                   -> scenario 23
# AC 8  probe cost bounded                                         -> scenarios 24-26
# AC 9  old fixed text gone                                        -> scenario 27 (grep)
# AC 10 PR title                                                   -> scenario 28 (PR title)
# AC 11 box run after merge                                        -> scenario 29 (box run)
