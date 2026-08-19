# Coverage map for claude-plugins#91 — the how-do-i gate denied
# WebFetch/WebSearch by omission. Not executable: each Scenario carries a
# "# proves:" comment naming the bats test that proves it.

Feature: The invariant gate treats web discovery as a look, not an act
  Read-only web lookup is part of the compliance path. Forming a good
  /how-do-i query can require looking something up first. By explicit
  spec decision the allow is unconditional — the gate applies no URL,
  domain or query filtering; its property is local mutation, which
  neither tool performs.

  # proves: hooks/tests/gate-libs.bats "allowlist: WebFetch is read-only discovery and allowed"
  Scenario: WebFetch is allowed
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebFetch with a url payload
    Then it returns 0

  # proves: hooks/tests/gate-libs.bats "allowlist: WebSearch is read-only discovery and allowed"
  Scenario: WebSearch is allowed
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebSearch with a query payload
    Then it returns 0

  # proves: hooks/tests/gate-libs.bats "allowlist: WebFetch/WebSearch are unconditional — payload not inspected"
  Scenario: The allow does not depend on the payload
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebFetch with an empty payload
    And it is asked about WebSearch with an empty JSON object
    Then it returns 0 for both

  # proves: hooks/tests/gate-libs.bats "allowlist: unknown tools still fall through to deny"
  Scenario: Unknown tools still deny by default
    Given the gate allowlist library
    When gal_is_compliance_path is asked about Edit, Write or an mcp__x__y tool
    Then it returns 1

  # proves: hooks/tests/gates.bats "how-do-i-gate: WebFetch is allowed while the gate is armed"
  Scenario: The hook layer allows WebFetch while the gate is armed
    Given a turn has started and Skill(how-do-i) has not run
    And the caller is a gated main agent
    When how-do-i-gate.sh receives a WebFetch tool call
    Then it exits 0 with empty stdout and the call is not denied
