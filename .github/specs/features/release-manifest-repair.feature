# Coverage map for claude-plugins#232 - release-please 17.3.0 reads the manifest once per run
# and later rewrites it on top of the current head of main. A release PR merged during the run
# leaves another plugin's release branch with an old manifest, so merging that PR would set the
# other plugin back. The next runs skip the branch ("remained the same"). A step after the action
# now compares each release branch with its own merge base and repairs it with one normal commit.
# Not executable: each Scenario carries a "# proves:" comment naming the bats test section or live
# command that proves it. The tests are in .github/scripts/tests/repair-release-manifests.bats,
# under the section headings "stale branch", "healthy branch", "skip and refuse",
# "failing gh calls", "several PRs, pagination, env", "usage" and "the 2026-10-10 incident".
# Delivery checks (workflow wiring greps AC9, AC10, AC11, AC12) are not product behavior and are
# proven in the PR body.
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

  # proves: bats section "stale branch"
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

  # proves: bats section "healthy branch"; live: DRY_RUN=1 on drewdrewthis/claude-plugins
  @integration
  Scenario: A healthy branch on an older main is not touched
    Given a release PR whose branch manifest equals the merge-base manifest plus its own line
    When the repair script runs
    Then it prints "ok: <ref>", sends no PUT and does not rewrite the branch although main moved on

  # proves: bats "incident 2026-10-10: ship set back by the procedures release branch is restored byte for byte"
  @integration
  Scenario: The 2026-10-10 incident is caught and restored byte for byte
    Given the branch manifest of e86b71e4 and the merge-base manifest of 284c1d7e
    When the repair script runs for component procedures
    Then the single PUT content equals "git show 24eb73a8:.release-please-manifest.json"

  # proves: bats sections "skip and refuse", "failing gh calls", "several PRs, pagination, env" and the dry-run tests in "stale branch"
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

  # proves: bats "check-release-title" suite unchanged and green; git diff --stat origin/main...HEAD lists neither release-please-config.json nor .release-please-manifest.json
  @integration
  Scenario: Existing release-title behavior and managed files are unchanged
    When "bats .github/scripts/tests" runs
    Then all pre-existing tests pass
    And the diff against main touches neither the config nor the manifest

  # proves: bats "reads carry the head sha and never the branch name; the PUT carries the branch"
  @integration
  Scenario: Every read of a release branch is pinned to one commit
    Given a release PR whose head sha is in the pull request list
    When the repair script runs
    Then the compare call and the manifest read use that sha and not the branch name
    And the PUT carries the branch name and the blob sha of that read, so a branch that moved gets a 409

  # proves: bats "the warning for a fork head does not contain the branch name"
  @integration
  Scenario: The warning for a pull request from another repository carries no ref
    Given a release-prefixed pull request whose head is in another repository
    When the repair script runs
    Then the ::warning:: line does not contain the branch name, because outsiders choose it
