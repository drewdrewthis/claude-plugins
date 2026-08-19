# Coverage map for orchard-codex/claude-plugins#91 — the how-do-i gate denied
# WebFetch/WebSearch by omission. Not executable; each Scenario names the bats
# test that proves it (hooks/tests/gate-libs.bats, hooks/tests/gates.bats).

Feature: The invariant gate treats web discovery as a look, not an act
  Read-only web lookup is part of the compliance path. Forming a good
  /how-do-i query can require looking something up first, and neither
  WebFetch nor WebSearch can mutate anything.

  Scenario: WebFetch is allowed
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebFetch with a url payload
    Then it returns 0

  Scenario: WebSearch is allowed
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebSearch with a query payload
    Then it returns 0

  Scenario: The allow is unconditional
    Given the gate allowlist library
    When gal_is_compliance_path is asked about WebFetch with an empty payload
    And it is asked about WebSearch with an empty JSON object
    Then it returns 0 for both
    And no URL, domain or query filtering is applied

  Scenario: Unknown tools still deny by default
    Given the gate allowlist library
    When gal_is_compliance_path is asked about Write or an mcp__x__y tool
    Then it returns 1

  Scenario: The hook layer allows WebFetch while the gate is armed
    Given a turn has started and Skill(how-do-i) has not run
    And the caller is a gated main agent
    When how-do-i-gate.sh receives a WebFetch tool call
    Then stdout is empty and the call is not denied
