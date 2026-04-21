#!/bin/bash
# lib/state.sh — state file 路径定义与基础工具
#
# 所有路径通过环境变量可覆盖（测试用）

: "${STATE_DIR:=$HOME/.local/state/oc-session-restore}"
: "${STATE_FILE:=$STATE_DIR/state.json}"
: "${SCAN_PID_FILE:=$STATE_DIR/scan.pid}"
: "${PREV_IDS_FILE:=$STATE_DIR/prev_ids.txt}"
: "${SAVED_IDS_FILE:=$STATE_DIR/saved_ids.txt}"

# 清空 state file
state_clear() {
  mkdir -p "$STATE_DIR"
  echo '{}' > "$STATE_FILE"
}
