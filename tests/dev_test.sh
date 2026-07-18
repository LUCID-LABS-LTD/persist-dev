#!/usr/bin/env bash
# Minimal source-based tests for dev (no tmux required for valid_name/load_config).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dev
source "$SCRIPT_DIR/../dev"

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

# valid_name: 0 for safe names, 1 for anything that could escape/traverse.
check "valid: simple"   0 valid_name "foo"
check "valid: dotted"   0 valid_name "foo.bar"
check "valid: mixed"    0 valid_name "a-b_c1"
check "invalid: empty"  1 valid_name ""
check "invalid: slash"  1 valid_name "foo/bar"
check "invalid: dotdot" 1 valid_name ".."
check "invalid: space"  1 valid_name "a b"
check "invalid: at"     1 valid_name "a@b"

# load_config creates a default config and registers the known harnesses.
CONFIG_DIR="$(mktemp -d)"; META_DIR="$CONFIG_DIR/.persist"; PROJECTS_DIR="$(mktemp -d)"
load_config
check "default harness set" 0 [ -n "$DEFAULT_HARNESS" ]
check "opencode known"     0 [ -n "${HARNESS_CMD[opencode]:-}" ]
check "agy known"          0 [ -n "${HARNESS_CMD[agy]:-}" ]

# harness_resolve
h=$(harness_resolve opencode)
check "resolve opencode"   0 [ "$h" = "opencode" ]

if [ "$fail" -ne 0 ]; then echo "$fail test(s) failed"; exit 1; fi
echo "all dev tests passed"
