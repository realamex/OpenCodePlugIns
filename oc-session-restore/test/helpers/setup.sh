#!/bin/bash
# test/helpers/setup.sh — 测试公共 setup/teardown 与断言工具
#
# 用法: source test/helpers/setup.sh

set -uo pipefail
# 注意：不使用 set -e，因为测试需要检查命令的退出状态

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ── 计数器 ──
_TEST_PASS=0
_TEST_FAIL=0
_TEST_TOTAL=0
_TEST_NAME=""

# ── 临时目录（隔离每次测试） ──
TEST_TMPDIR=""

setup_test_env() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test.XXXXXX")
  export STATE_DIR="$TEST_TMPDIR/state"
  export STATE_FILE="$STATE_DIR/state.json"
  export SCAN_PID_FILE="$STATE_DIR/scan.pid"
  mkdir -p "$STATE_DIR"
}

teardown_test_env() {
  [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ── 测试运行器 ──
describe() {
  echo -e "\n${YELLOW}== $1 ==${NC}"
}

it() {
  _TEST_NAME="$1"
  _TEST_TOTAL=$((_TEST_TOTAL + 1))
}

pass() {
  _TEST_PASS=$((_TEST_PASS + 1))
  echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
}

fail() {
  _TEST_FAIL=$((_TEST_FAIL + 1))
  echo -e "  ${RED}✗${NC} $_TEST_NAME"
  echo -e "    ${RED}$1${NC}"
}

# ── 断言 ──
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    pass
  else
    fail "Expected: '$expected', Got: '$actual' ${msg}"
  fi
}

assert_ne() {
  local not_expected="$1" actual="$2" msg="${3:-}"
  if [ "$not_expected" != "$actual" ]; then
    pass
  else
    fail "Expected NOT: '$not_expected', Got: '$actual' ${msg}"
  fi
}

assert_file_exists() {
  if [ -f "$1" ]; then
    pass
  else
    fail "File not found: $1"
  fi
}

assert_file_not_exists() {
  if [ ! -f "$1" ]; then
    pass
  else
    fail "File should not exist: $1"
  fi
}

assert_json_field() {
  local file="$1" jq_expr="$2" expected="$3"
  local actual
  actual=$(jq -r "$jq_expr" "$file" 2>/dev/null || echo "__JQ_ERROR__")
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "JSON $jq_expr: Expected '$expected', Got '$actual'"
  fi
}

assert_json_field_exists() {
  local file="$1" jq_expr="$2"
  local actual
  actual=$(jq -r "$jq_expr" "$file" 2>/dev/null || echo "null")
  if [ "$actual" != "null" ] && [ "$actual" != "" ]; then
    pass
  else
    fail "JSON field $jq_expr should exist and be non-null"
  fi
}

assert_json_field_empty() {
  local file="$1" jq_expr="$2"
  local actual
  actual=$(jq -r "$jq_expr" "$file" 2>/dev/null || echo "__ERROR__")
  if [ "$actual" = "" ] || [ "$actual" = "null" ]; then
    pass
  else
    fail "JSON field $jq_expr should be empty/null, got '$actual'"
  fi
}

assert_json_count() {
  local file="$1" jq_expr="$2" expected="$3"
  local actual
  actual=$(jq "$jq_expr" "$file" 2>/dev/null || echo "-1")
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "JSON count $jq_expr: Expected $expected, Got $actual"
  fi
}

assert_exit_code() {
  local expected="$1"
  shift
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    pass
  else
    fail "Exit code: Expected $expected, Got $actual (cmd: $*)"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  if echo "$haystack" | grep -qF "$needle"; then
    pass
  else
    fail "String should contain '$needle'"
  fi
}

# ── 摘要 ──
print_summary() {
  echo ""
  echo "────────────────────────────────"
  if [ "$_TEST_FAIL" -eq 0 ]; then
    echo -e "${GREEN}All $_TEST_TOTAL tests passed.${NC}"
  else
    echo -e "${RED}$_TEST_FAIL/$_TEST_TOTAL tests failed.${NC}"
  fi
  echo "────────────────────────────────"
  return "$_TEST_FAIL"
}
