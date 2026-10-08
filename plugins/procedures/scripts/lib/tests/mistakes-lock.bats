#!/usr/bin/env bats
# Tests for scripts/lib/mistakes-lock.sh — the mkdir fallback (flock absent).
# Run: bats scripts/lib/tests/mistakes-lock.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../mistakes-lock.sh"
  D="$(mktemp -d)"
  export MISTAKES_NO_FLOCK=1 MISTAKES_LOCK_WAIT_SECS=0
}

@test "a stale lock is taken over even when it holds files (renamed, not removed in place)" {
  mkdir "$D/l.d"; : > "$D/l.d/owner"
  touch -d '-5 minutes' "$D/l.d"
  run bash -c "source '$LIB'; mistakes_locked '$D/l' true"
  [ "$status" -eq 0 ]
  [ ! -e "$D/l.d" ]
}

@test "a fresh lock is never stolen" {
  mkdir "$D/l.d"
  run bash -c "source '$LIB'; mistakes_locked '$D/l' true"
  [ "$status" -eq 75 ]
  [ -d "$D/l.d" ]
}

@test "the lock is released when the locked command exits the shell" {
  run bash -c "source '$LIB'; mistakes_locked '$D/l' exit 3"
  [ "$status" -eq 3 ]
  [ ! -e "$D/l.d" ]
}

@test "the lock is released when the holder is terminated" {
  bash -c "source '$LIB'; mistakes_locked '$D/l' sleep 2" &
  local pid=$! i=0
  until [ -d "$D/l.d" ] || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -d "$D/l.d" ]
  kill -TERM "$pid"; wait "$pid" || true
  [ ! -e "$D/l.d" ]
}
