#!/bin/bash
# test/run_all.sh — 运行所有测试
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_FAIL=0

echo "============================================"
echo " OC Session Restore — Test Suite"
echo "============================================"

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  echo ""
  echo "▶ Running $(basename "$test_file")..."
  echo "--------------------------------------------"
  bash "$test_file"
  TOTAL_FAIL=$((TOTAL_FAIL + $?))
done

echo ""
echo "============================================"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo " ALL TEST SUITES PASSED"
else
  echo " $TOTAL_FAIL TEST SUITE(S) HAD FAILURES"
fi
echo "============================================"

exit "$TOTAL_FAIL"
