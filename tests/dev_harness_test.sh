#!/usr/bin/env bash
# Tests dev-harness restart policy without a real agent (uses true/false).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dev-harness
source "$SCRIPT_DIR/../dev-harness"

fail=0
check() {
  local desc="$1" expected="$2"; shift 2
  if "$@"; then got=0; else got=1; fi
  if [ "$got" -eq "$expected" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

# Clean exit -> not restarting.
out=$(DEV_HARNESS_MAX=3 DEV_HARNESS_BASE_DELAY=0 run_harness t1 true)
check "clean exit: not restarting" 0 echo "$out" | grep -q "not restarting"

# Crash -> restarts up to max, then gives up.
out=$(DEV_HARNESS_MAX=2 DEV_HARNESS_BASE_DELAY=0 run_harness t2 false)
check "crash: gives up after max"   0 echo "$out" | grep -q "giving up"

# Stop flag -> exits without spawning another instance. Use a writable flag dir.
flag_dir="$(mktemp -d)"
export DEV_HARNESS_FLAG_DIR="$flag_dir"
touch "$flag_dir/t3.norestart"
out=$(DEV_HARNESS_MAX=5 DEV_HARNESS_BASE_DELAY=0 run_harness t3 false)
check "stop flag: not restarting"   0 echo "$out" | grep -q "stop flag set"
unset DEV_HARNESS_FLAG_DIR
rm -rf "$flag_dir"

if [ "$fail" -ne 0 ]; then echo "$fail test(s) failed"; exit 1; fi
echo "all dev-harness tests passed"
