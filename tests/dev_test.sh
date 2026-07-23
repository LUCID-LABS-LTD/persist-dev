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

# cmd_help
help_out=$(cmd_help)
check "cmd_help output" 0 grep -q "persist-dev CLI" <<< "$help_out"

# cmd_ctx
CTX_DIR="$(mktemp -d)"
# test edit / show with .md extension cleaning
EDITOR="echo" cmd_ctx edit testnote.md >/dev/null
check "ctx note created with clean name" 0 [ -f "$CTX_DIR/testnote.md" ]
show_out=$(cmd_ctx show testnote)
check "ctx show testnote" 0 grep -q "Context: testnote" <<< "$show_out"
show_md_out=$(cmd_ctx show testnote.md)
check "ctx show testnote.md" 0 grep -q "Context: testnote" <<< "$show_md_out"

# test editor fallback
ed_out=$(EDITOR="echo" cmd_ctx edit note2)
check "ctx edit note2" 0 [ -f "$CTX_DIR/note2.md" ]

# cmd_ls_raw
mkdir -p "$PROJECTS_DIR/alpha" "$PROJECTS_DIR/beta" "$PROJECTS_DIR/.persist"
raw_out=$(cmd_ls_raw)
check "cmd_ls_raw contains alpha" 0 grep -q "^alpha$" <<< "$raw_out"
check "cmd_ls_raw contains beta"  0 grep -q "^beta$" <<< "$raw_out"
check "cmd_ls_raw excludes .persist" 1 grep -q "\.persist" <<< "$raw_out"

# cmd_log (reading log file when session is gone)
echo "log line 1" > "$META_DIR/alpha.log"
echo "log line 2" >> "$META_DIR/alpha.log"
log_out=$(cmd_log -n 1 alpha)
check "cmd_log fallback to log file" 0 grep -q "log line 2" <<< "$log_out"

# cmd_doctor
doc_out=$(cmd_doctor)
check "cmd_doctor contains volume" 0 grep -q "volume /workspace" <<< "$doc_out"
check "cmd_doctor contains tailscale" 0 grep -q "tailscale" <<< "$doc_out"

if [ "$fail" -ne 0 ]; then echo "$fail test(s) failed"; exit 1; fi
echo "all dev tests passed"
