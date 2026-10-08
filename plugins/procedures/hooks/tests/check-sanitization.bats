#!/usr/bin/env bats
# Tests for scripts/check-sanitization.sh — the leak-class baseline check.
# PLUGIN ADAPTATION: no upstream counterpart — tests for new librarian commit-gate machinery.
# One case per leak class (AC2) plus the /home/ubuntu/ carve-out and a clean pass,
# and hardened path cases (uppercase user, mixed line, traversal).
# Run: bats hooks/tests/check-sanitization.bats

# setup — resolve the script under test and a fresh tmp fixture dir.
setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/check-sanitization.sh"
  FIX="$(mktemp -d)"
}
# teardown — remove the tmp fixture tree.
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

@test "macOS personal home path with uppercase username is rejected" {
  _clean_record
  printf 'path: /Users/Alice/secret\n' >> "$FIX/rec.md"
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

@test "allowed and personal Linux paths on one line still trips" {
  _clean_record
  printf 'paths: /home/ubuntu/ok and /home/bob/private\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux home path"* ]]
}

@test "Linux traversal out of the allowed /home/ubuntu segment is rejected" {
  _clean_record
  printf 'path: /home/ubuntu/../alice/secret\n' >> "$FIX/rec.md"
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

@test "Slack token: the report names the line, never the token" {
  _clean_record
  printf 'token: xoxb-123-abcsecret\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Slack token"*"line 12"* ]]
  [[ "$output" != *"abcsecret"* ]]
}

# ---- --strict: the extra classes for transcript-derived jsonl rows ----
# _strict_case <label> <row-text> <secret> — one row, rejected under --strict
# with <label> and a line number, and <secret> never echoed.
_strict_case() {
  printf '{"a":1}\n{"d":"%s"}\n' "$2" > "$FIX/row.jsonl"
  run bash "$SCRIPT" --strict "$FIX/row.jsonl"
  [ "$status" -ne 0 ] || { echo "not rejected: $2"; return 1; }
  [[ "$output" == *"$1"*"line 2"* ]] || { echo "wrong report for $2: $output"; return 1; }
  [[ "$output" != *"$3"* ]] || { echo "echoed secret $3: $output"; return 1; }
}

@test "--strict rejects each extra leak class without echoing it" {
  _strict_case "macOS home path"   '/Users/alice'                              alice
  _strict_case "Linux home path"   '/home/bob'                                 bob
  _strict_case "macOS home path"   '\/Users\/alice\/x'                          alice
  _strict_case "Windows home path" 'C:\\Users\\alice'                          alice
  _strict_case "GitHub token"      'ghp_abcdefghijklmnopqrstuvwxyz0123456789'  abcdefghij
  _strict_case "GitHub token"      'github_pat_11ABCDEFG0abcdefghijklmnop'     abcdefghij
  _strict_case "API key"           'sk-ant-api03-zzzzzzzz'                     zzzzzzzz
  _strict_case "API key"           'sk-abcdefghijklmnopqrstuvwx'               abcdefghij
  _strict_case "AWS key"           'AKIAABCDEFGHIJKLMNOP'                      ABCDEFGHIJ
  _strict_case "bearer token"      'Bearer abcdefghijklmnopqrstuvwxyz'         abcdefghij
  _strict_case "credential"        'PASSWORD=hunter2hunter2xx'                 hunter2
}

@test "--strict still allows /home/ubuntu and a clean row" {
  printf '{"d":"ran in /home/ubuntu and /home/ubuntu/work, sk-short, a ghp_ mention"}\n' > "$FIX/row.jsonl"
  run bash "$SCRIPT" --strict "$FIX/row.jsonl"
  [ "$status" -eq 0 ]
}

@test "without --strict a slashless /Users/alice is not flagged (.md behaviour unchanged)" {
  _clean_record
  printf 'see /Users/alice\n' >> "$FIX/rec.md"
  run bash "$SCRIPT" "$FIX/rec.md"
  [ "$status" -eq 0 ]
}

@test "--strict leaves placeholder and prose rows alone" {
  printf '%s\n' \
    '{"d":"never put a primary key: some_column_name_here in a row"}' \
    '{"d":"see /home/<user>/ and /Users/<name> placeholders"}' \
    '{"d":"see /home/<user>/x, /Users/me, /home/someone/, C:\\Users\\<name>"}' \
    '{"d":"set API_KEY=<your-key> or TOKEN=${GITHUB_TOKEN} or PASSWORD=example1234567890abc"}' > "$FIX/row.jsonl"
  run bash "$SCRIPT" --strict "$FIX/row.jsonl"
  [ "$status" -eq 0 ]
}

@test "--strict reads rows from stdin when the file is -" {
  run bash -c "printf '%s\n' '{\"d\":\"/Users/alice\"}' | bash '$SCRIPT' --strict -"
  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS home path (line 1)"* ]]
}

@test "--strict skips a hit only when the whole value is a placeholder" {
  _strict_case "credential"   'API_KEY=Abc123def4567890xyzQ\nPATH=$PATH'   Abc123def
  _strict_case "credential"   'TOKEN=Abc123def4567890xyzQ\n<user>'         Abc123def
  _strict_case "credential"   'API_KEY=Ab3$Dxyz1234567890qq'               Dxyz1234
  _strict_case "GitHub token" 'ghp_xxxAb3Cd4Ef5Gh6Ij7Kl8Mn9Op0Qr1St2Uv3'   Cd4Ef5
  _strict_case "macOS home path" '/Users/$USER'                            USER
  _strict_case "Linux home path" '/home/example/x'                         example
  _strict_case "credential"   'PASSWORD=Hunter2,Xyzzy99abcdefghij'        Xyzzy99
  _strict_case "credential"   'TOKEN=abcdefghijklmnop,qrst1234567890'      qrst1234
  _strict_case "credential"   'API_KEY=abc\"def1234567890ghij'            def12345
}

@test "--strict allows /home/ubuntu followed by punctuation" {
  printf '{"d":"ran in /home/ubuntu. then /home/ubuntu, and (/home/ubuntu)"}\n' > "$FIX/row.jsonl"
  run bash "$SCRIPT" --strict "$FIX/row.jsonl"
  [ "$status" -eq 0 ]
}
