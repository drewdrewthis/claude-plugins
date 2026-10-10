# Coverage map for claude-plugins#232 - release-please 17.3.0 reads the manifest once per run
# and later rewrites it on top of the current head of main. A release PR merged during the run
# leaves another plugin's release branch with an old manifest, so merging that PR would set the
# other plugin back. The next runs skip the branch ("remained the same"). A step after the action
# now compares each release branch with its own merge base and repairs it with one normal commit.
# Not executable: each Scenario carries a "# proves:" comment naming the bats test or live
# command that proves it. Bats names are in .github/scripts/tests/repair-release-manifests.bats.
# @e2e scenarios run on the private scratch repo drewdrewthis/scratch-rp-race-232, never here.

Feature: A release branch that sets another plugin back is repaired in the same run
  The branch manifest must equal the manifest at the branch merge base, except for the
  branch's own plugin line. Anything the script does not understand turns the run red
  and repairs nothing for that PR.

  # proves: scratch repo run, quoted logs: "repaired: release-please--branches--main--components--a", one new commit, one - and one + line in the manifest diff
  @e2e
  Scenario: A stale release branch is repaired by a real workflow run
    Given the scratch repo has the workflow step and "always-update" is null in its config
    And release branch a has plugin b set back against its merge base
    When a push to main that touches no plugins path runs the workflow
    Then the repair step logs "repaired: release-please--branches--main--components--a" with a warning annotation
    And branch a gains exactly one commit that changes only the manifest, only the plugins/a line against the merge base
    And PR a keeps its number, state, title, body and labels

  # proves: bats "stale branch gives exactly one PUT", "stale branch PUT targets the release branch", "stale branch PUT carries the blob sha read from the release branch", "stale branch PUT content is the merge-base manifest with the own line from the branch", "stale branch never sends a PUT without a branch field"
  @integration
  Scenario: A stale branch gets one PUT on its own branch with the expected bytes
    Given a release PR whose branch manifest sets plugins/beta back against the merge base
    When the repair script runs
    Then it sends exactly one PUT with branch, sha and the merge-base manifest with the own line from the branch
    And it never sends a PUT without a branch field

  # proves: scratch repo, observed with a Node preload hook on release-please 17.3.0; quoted terminal output
  @e2e
  Scenario: The upstream bug reproduces and the next plain run does not repair it
    Given release-please 17.3.0 runs unmodified against the scratch repo
    When a hook merges plugin b's release PR between the manifest read and the branch write
    Then the branch for a has the new main as parent and sets plugins/b back
    And the next plain run logs "remained the same" and the head sha of a does not change

  # proves: scratch repo, quoted logs and shas
  @e2e
  Scenario: The next run neither undoes nor fights the repair
    Given branch a was repaired
    When a later push touches no plugins/a path
    Then the logs show "remained the same" and "ok: release-please--branches--main--components--a" and the head sha is equal
    When a later push changes the body of PR a so release-please rebuilds the branch
    Then the repair step logs "ok: release-please--branches--main--components--a"

  # proves: scratch repo, squash merge of the repaired PR, quoted manifest, git ls-remote --tags, run URL
  @e2e
  Scenario: A repaired PR merges and releases
    Given the repaired PR a
    When it is squash merged
    Then the manifest on main has a and b at their new versions
    And the next run creates the tag "a-v<new>"

  # proves: bats "healthy branch on an older main gives zero PUT", "healthy branch reports ok and exits 0", "the manifest is never read from the tip of the base branch"; live: DRY_RUN=1 on drewdrewthis/claude-plugins
  @integration
  Scenario: A healthy branch on an older main is not touched
    Given a release PR whose branch manifest equals the merge-base manifest plus its own line
    When the repair script runs
    Then it prints "ok: <ref>", sends no PUT and never reads the manifest from main

  # proves: bats "incident 2026-10-10: ship set back by the procedures release branch is restored byte for byte"
  @integration
  Scenario: The 2026-10-10 incident is caught and restored byte for byte
    Given the branch manifest of e86b71e4 and the merge-base manifest of 284c1d7e
    When the repair script runs for component procedures
    Then the single PUT content equals "git show 24eb73a8:.release-please-manifest.json"

  # proves: bats "fork head is skipped with a warning", "fork head gives zero PUT, exit 0 and counts as checked", "head.repo null is skipped like a fork", "unknown component is an error", "missing own line on the branch is an error", "missing autorelease pending label is an error", "branch name outside the strict pattern is an error", "branch name outside the strict pattern triggers no call beyond the list", "failing pulls list is an error", "failing compare call is an error for that PR", "failing merge-base manifest read is an error for that PR", "failing head manifest read is an error for that PR", "PUT rejected with HTTP 409 is an error and is not reported as repaired", "PUT rejected with HTTP 409 is not retried", "two other lines set back are both restored", "a line present at the merge base and absent on the branch is restored", "DRY_RUN=1 on a stale branch reports would repair", "DRY_RUN=1 on a stale branch writes nothing", "DRY_RUN=1 on a stale branch exits 0", "an error on PR 1 does not stop the repair of PR 2", "an error on PR 1 makes the run exit non-zero and counts both PRs", "two concatenated pages from --paginate are both read", "no pull requests at all ends with checked 0 and exit 0"
  @integration
  Scenario Outline: Failure modes
    Given a release PR in the state "<state>"
    When the repair script runs
    Then the outcome is "<outcome>" and the last line is "checked: <N> release PR(s)"

    Examples:
      | state                                     | outcome                               |
      | fork head or head.repo null               | skip, zero PUT, exit 0                |
      | unknown component                         | ::error::, zero PUT, non-zero exit    |
      | missing own line on the branch            | ::error::, zero PUT, non-zero exit    |
      | no autorelease pending label              | ::error::, zero PUT, non-zero exit    |
      | branch name outside the strict pattern    | ::error::, zero PUT, non-zero exit    |
      | any failing gh call                       | ::error::, zero PUT, non-zero exit    |
      | PUT rejected with HTTP 409                | ::error::, not retried, non-zero exit |
      | two other lines set back                  | both restored in one PUT              |
      | line absent on the branch                 | restored in one PUT                   |
      | DRY_RUN=1 on a stale branch               | would repair, zero PUT, exit 0        |
      | error on PR 1, stale PR 2                 | PR 2 repaired, non-zero exit          |
      | no release PRs                            | checked: 0, exit 0                    |

  # proves: workflow diff and grep output (permissions and concurrency byte-equal to main, persist-credentials false, if: ${{ !cancelled() }}, no eval, grep -c 'would race' returns 0); security review lane
  @unit
  Scenario: The workflow wiring is minimal and safe
    Given the release-please workflow with the repair step
    Then the step runs after the action with "if: ${{ !cancelled() }}"
    And "permissions:" and "concurrency:" are byte-equal to main
    And the checkout uses persist-credentials false
    And the script has no eval, passes API data to jq with --arg or stdin, and writes only the manifest path

  # proves: quoted diff hunk of CONTRIBUTING.md section "Versioning - automated, never by hand"
  @unit
  Scenario: The docs state what the step does and the merge rule
    Given CONTRIBUTING.md
    Then the section states what the repair step does
    And it says not to merge a release PR while a release-please run is in progress or failed

  # proves: bats "check-release-title" suite unchanged and green; git diff --stat origin/main...HEAD lists neither release-please-config.json nor .release-please-manifest.json
  @integration
  Scenario: Existing release-title behavior and managed files are unchanged
    When "bats .github/scripts/tests" runs
    Then all pre-existing tests pass
    And the diff against main touches neither the config nor the manifest

  # proves: snapshots at T0 and T1 of PR 195 and PR 190 (head sha, state, title, body hash, labels), tags and releases, run list
  @e2e
  Scenario: Open release PRs, tags and releases of this repo are unchanged
    Given a snapshot at T0 and one when this PR is ready
    Then each difference is explained by a push-event run of a merge that is not this PR
    And no workflow_dispatch run and no run_attempt above 1 occurred in between

  # proves: the PR body section "Residual risk" (quoted)
  @unit
  Scenario: Residual risk and rollback are stated
    Given the PR body
    Then "Residual risk" states that the stale write is not prevented, the open window, and the rollback by revert
