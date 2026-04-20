#!/bin/bash
# test/test_scan.sh — oc-scan 全量快照测试

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers/setup.sh"

SCAN_MOCK_DIR=""

setup_scan_mock() {
  SCAN_MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/scan-mock.XXXXXX")

  cat > "$SCAN_MOCK_DIR/cmux" << 'ENDMOCK'
#!/bin/bash
case "$1" in
  tree)
    # 忽略 --all --json 等标志，直接返回 mock 数据
    echo "${MOCK_CMUX_TREE_JSON}" ;;
  read-screen)
    ws=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) ws="$2"; shift 2 ;; *) shift ;; esac; done
    varname="MOCK_READSCREEN_$(echo "$ws" | tr ':' '_' | tr '[:lower:]' '[:upper:]')"
    eval "echo \"\${$varname:-}\""
    ;;
  new-workspace) echo "new-workspace $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"; echo "OK workspace:99" ;;
  new-split) echo "new-split $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"; echo "OK surface:99 workspace:99" ;;
  send) echo "send $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}" ;;
esac
ENDMOCK

  cat > "$SCAN_MOCK_DIR/opencode" << 'ENDMOCK'
#!/bin/bash
[ "$1" = "session" ] && [ "$2" = "list" ] && cat "${MOCK_SESSIONS_FILE}" && exit 0
ENDMOCK

  cat > "$SCAN_MOCK_DIR/ps" << 'ENDMOCK'
#!/bin/bash
[[ "$*" == *"-eo"*"pid="*"comm="* ]] && { cat "${MOCK_PS_PIDLIST}"; exit 0; }
[[ "$*" == *"eww"*"args="* ]] && { pid=$(echo "$@" | grep -oE '[0-9]+$'); cat "${MOCK_ENV_DIR}/${pid}.env" 2>/dev/null; exit 0; }
[[ "$*" == *"tty="* ]] && { pid=$(echo "$@" | grep -oE '[0-9]+$'); cat "${MOCK_ENV_DIR}/${pid}.tty" 2>/dev/null; exit 0; }
/bin/ps "$@"
ENDMOCK

  cat > "$SCAN_MOCK_DIR/lsof" << 'ENDMOCK'
#!/bin/bash
echo "n${MOCK_CWD:-/tmp}"
ENDMOCK

  chmod +x "$SCAN_MOCK_DIR"/*
  export PATH="$SCAN_MOCK_DIR:$PATH"
}

setup_scan_data() {
  export MOCK_SESSIONS_FILE="$TEST_TMPDIR/sessions.json"
  echo '[{"id":"ses_AAA","title":"Session Alpha","updated":1000},{"id":"ses_BBB","title":"Session Beta","updated":2000}]' > "$MOCK_SESSIONS_FILE"

  # 多 window 结构（--all 返回所有 window 的数据）
  export MOCK_CMUX_TREE_JSON='{"windows":[{"workspaces":[{"ref":"workspace:1","title":"OC | Session Alpha","panes":[{"surfaces":[{"ref":"surface:1","type":"terminal","tty":"ttys001","title":"OpenCode"}]}]}]},{"workspaces":[{"ref":"workspace:2","title":"OC | Session Beta","panes":[{"surfaces":[{"ref":"surface:2","type":"terminal","tty":"ttys002","title":"OpenCode"}]}]}]}]}'

  PAD="                                                                                                                                                                             "
  export MOCK_READSCREEN_WORKSPACE_1="line1
${PAD}Session Alpha
line3
${PAD}Context"
  export MOCK_READSCREEN_WORKSPACE_2="line1
${PAD}Session Beta
line3
${PAD}Context"

  export MOCK_PS_PIDLIST="$TEST_TMPDIR/pidlist.txt"
  printf '  1001 opencode\n  1002 opencode\n' > "$MOCK_PS_PIDLIST"

  export MOCK_ENV_DIR="$TEST_TMPDIR/env"
  mkdir -p "$MOCK_ENV_DIR"
  echo "opencode CMUX_SURFACE_ID=surface-uuid-1 CMUX_WORKSPACE_ID=ws-uuid-1" > "$MOCK_ENV_DIR/1001.env"
  echo "ttys001" > "$MOCK_ENV_DIR/1001.tty"
  echo "opencode CMUX_SURFACE_ID=surface-uuid-2 CMUX_WORKSPACE_ID=ws-uuid-2" > "$MOCK_ENV_DIR/1002.env"
  echo "ttys002" > "$MOCK_ENV_DIR/1002.tty"

  export MOCK_CWD="/tmp/project"
}

teardown_scan_mock() {
  [ -n "$SCAN_MOCK_DIR" ] && rm -rf "$SCAN_MOCK_DIR"
}

# ─────────────────────────────────────────────
describe "oc-scan — 防重复执行"
# ─────────────────────────────────────────────

it "should clean up PID file after completion"
setup_test_env
setup_scan_mock
setup_scan_data
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_file_not_exists "$SCAN_PID_FILE"
teardown_scan_mock
teardown_test_env

it "should kill old scan when new scan starts"
setup_test_env
setup_scan_mock
setup_scan_data
sleep 60 &
old_pid=$!
echo "$old_pid" > "$SCAN_PID_FILE"
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
kill -0 "$old_pid" 2>/dev/null && result="alive" || result="dead"
assert_eq "dead" "$result" "old scan process should be killed"
teardown_scan_mock
teardown_test_env

# ─────────────────────────────────────────────
describe "oc-scan — 原子写入"
# ─────────────────────────────────────────────

it "should write state file with all found sessions"
setup_test_env
setup_scan_mock
setup_scan_data
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_file_exists "$STATE_FILE"
assert_json_count "$STATE_FILE" 'keys | length' "2"
teardown_scan_mock
teardown_test_env

it "should write correct sessionId for each surface"
setup_test_env
setup_scan_mock
setup_scan_data
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_json_field "$STATE_FILE" '."surface-uuid-1".sessionId' "ses_AAA"
assert_json_field "$STATE_FILE" '."surface-uuid-2".sessionId' "ses_BBB"
teardown_scan_mock
teardown_test_env

it "should write correct workspaceId and cwd"
setup_test_env
setup_scan_mock
setup_scan_data
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_json_field "$STATE_FILE" '."surface-uuid-1".workspaceId' "ws-uuid-1"
assert_json_field "$STATE_FILE" '."surface-uuid-1".cwd' "/tmp/project"
teardown_scan_mock
teardown_test_env

it "should overwrite previous state file entirely"
setup_test_env
setup_scan_mock
setup_scan_data
echo '{"old-surface":{"sessionId":"ses_OLD","workspaceId":"ws-old","cwd":"/old"}}' > "$STATE_FILE"
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_json_count "$STATE_FILE" 'keys | length' "2"
assert_json_field_empty "$STATE_FILE" '."old-surface"'
teardown_scan_mock
teardown_test_env

it "should not leave tmp files after successful scan"
setup_test_env
setup_scan_mock
setup_scan_data
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
tmp_count=$(find "$STATE_DIR" -name 'scan.tmp.*' 2>/dev/null | wc -l | xargs)
assert_eq "0" "$tmp_count" "no tmp files should remain"
teardown_scan_mock
teardown_test_env

# ─────────────────────────────────────────────
describe "oc-scan — 多 window 支持"
# ─────────────────────────────────────────────

it "should find sessions across multiple windows"
setup_test_env
setup_scan_mock
setup_scan_data
# MOCK_CMUX_TREE_JSON 已在 setup_scan_data 中设置为 2 个 window，各 1 个 workspace
"$PROJECT_DIR/bin/oc-scan" --quiet 2>/dev/null
assert_json_count "$STATE_FILE" 'keys | length' "2"
assert_json_field "$STATE_FILE" '."surface-uuid-1".sessionId' "ses_AAA"
assert_json_field "$STATE_FILE" '."surface-uuid-2".sessionId' "ses_BBB"
teardown_scan_mock
teardown_test_env

# ─────────────────────────────────────────────
describe "oc-scan — 边界情况"
# ─────────────────────────────────────────────

it "should write empty state when no OC workspaces found"
setup_test_env
setup_scan_mock
setup_scan_data
export MOCK_CMUX_TREE_JSON='{"windows":[{"workspaces":[{"ref":"workspace:1","title":"Terminal","panes":[{"surfaces":[{"ref":"surface:1","type":"terminal","tty":"ttys001","title":"zsh"}]}]}]}]}'
"$PROJECT_DIR/bin/oc-scan" 2>/dev/null
assert_json_count "$STATE_FILE" 'keys | length' "0"
teardown_scan_mock
teardown_test_env

it "should output nothing in --quiet mode"
setup_test_env
setup_scan_mock
setup_scan_data
output=$("$PROJECT_DIR/bin/oc-scan" --quiet 2>&1)
assert_eq "" "$output" "quiet mode should produce no output"
teardown_scan_mock
teardown_test_env

# ── 输出摘要 ──
print_summary
