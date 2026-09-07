#!/usr/bin/env bats
# Tests for scripts/check-sanitization.sh — the leak-class baseline check.
# One case per leak class (AC2) plus the /home/ubuntu/ carve-out and a clean pass.
# Run: bats hooks/tests/check-sanitization.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/check-sanitization.sh"
  FIX="$(mktemp -d)"
}
teardown() { rm -rf "$FIX"; }

# A well-formed record body with nothing to leak.
_clean_record() {
  cat > "$FIX/rec.md" <<'EOF'
---
id: fm.clean
kind: failure-mode
date: 2026-09-05
keywords: [k]
links: {}
status: active
description: a clean record.
---
# rec
body under /home/ubuntu/work is allowed.
EOF
}

@test "clean record passes (exit 0)" {
  _clean_record
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -eq 0 ]
}

@test "macOS personal home path is rejected" {
  _clean_record
  printf 'path: /Users/alice/secret\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS home path"* ]]
}

@test "Linux personal home path is rejected" {
  _clean_record
  printf 'path: /home/bob/private\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux home path"* ]]
}

@test "/home/ubuntu/ path is allowed (carve-out)" {
  _clean_record
  printf 'path: /home/ubuntu/runner/work\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -eq 0 ]
}

@test "Slack token is rejected" {
  _clean_record
  printf 'token: xoxb-123-abc\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Slack token"* ]]
}

@test "private key material is rejected" {
  _clean_record
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"private key material"* ]]
}
