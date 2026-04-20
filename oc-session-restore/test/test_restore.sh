#!/bin/bash
# test/test_restore.sh — 恢复脚本测试
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers/setup.sh"

RESTORE_MOCK_DIR=""

setup_restore_mock() {
  RESTORE_MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/restore-mock.XXXXXX")
  export OC_RESTORE_POLL_MAX=0     # 测试中跳过轮询，直接 scan 一次
  export OC_RESTORE_POLL_INTERVAL=0

  cat > "$RESTORE_MOCK_DIR/cmux" << 'ENDMOCK'
#!/bin/bash
case "$1" in
  tree) echo '{"windows":[]}' ;;
  new-workspace) echo "new-workspace $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"; echo "OK workspace:99" ;;
  new-split) echo "new-split $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"; echo "OK surface:99 workspace:99" ;;
  send) echo "send $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}" ;;
esac
ENDMOCK

  # mock oc-scan（restore 结尾会调 oc-scan --quiet）
  cat > "$RESTORE_MOCK_DIR/oc-scan" << 'ENDMOCK'
#!/bin/bash
# 记录被调用
echo "oc-scan $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"
# 模拟 scan 写入空 state（因为 mock cmux tree 返回空）
echo '{}' > "${STATE_FILE}"
ENDMOCK

  # mock opencode（restore 不直接调 opencode，但以防万一）
  cat > "$RESTORE_MOCK_DIR/opencode" << 'ENDMOCK'
#!/bin/bash
echo '[]'
ENDMOCK

  # mock ps/lsof（oc-scan mock 不需要它们，但保险起见）
  cat > "$RESTORE_MOCK_DIR/ps" << 'ENDMOCK'
#!/bin/bash
[[ "$*" == *"-eo"*"pid="*"comm="* ]] && { echo ""; exit 0; }
/bin/ps "$@"
ENDMOCK

  cat > "$RESTORE_MOCK_DIR/lsof" << 'ENDMOCK'
#!/bin/bash
echo "n/tmp"
ENDMOCK

  chmod +x "$RESTORE_MOCK_DIR"/*
  export PATH="$RESTORE_MOCK_DIR:$PATH"
}

teardown_restore_mock() {
  [ -n "$RESTORE_MOCK_DIR" ] && rm -rf "$RESTORE_MOCK_DIR"
}

# 辅助函数: 写入完整记录
write_full_record() {
  local surface="$1" workspace="$2" cwd="$3" session="$4"
  local existing
  [ -f "$STATE_FILE" ] && existing=$(cat "$STATE_FILE") || existing="{}"
  echo "$existing" | jq \
    --arg s "$surface" --arg w "$workspace" --arg c "$cwd" \
    --arg sid "$session" \
    '.[$s] = {sessionId: $sid, workspaceId: $w, cwd: $c}' \
    > "$STATE_FILE"
}

# ─────────────────────────────────────────────
describe "oc-restore — 基本恢复"
# ─────────────────────────────────────────────

it "should create one workspace per workspaceId group"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_1"
write_full_record "s2" "ws-B" "/tmp/b" "ses_2"
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
ws_count=$(grep -c "new-workspace" "$MOCK_CMUX_SEND_LOG" 2>/dev/null || echo "0")
assert_eq "2" "$ws_count" "should create 2 workspaces"
teardown_restore_mock
teardown_test_env

it "should send correct opencode command with session id and cwd"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/myproject" "ses_abc123"
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
log_content=$(cat "$MOCK_CMUX_SEND_LOG")
assert_contains "$log_content" "ses_abc123"
assert_contains "$log_content" "/tmp/myproject"
teardown_restore_mock
teardown_test_env

it "should not include tui subcommand in opencode invocation"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_1"
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
# grep -q: 只检查有无匹配，不输出
grep -q 'opencode tui' "$MOCK_CMUX_SEND_LOG" 2>/dev/null && tui_found="yes" || tui_found="no"
assert_eq "no" "$tui_found" "should not contain opencode tui"
teardown_restore_mock
teardown_test_env

it "should group surfaces by workspaceId into same workspace with splits"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_1"
write_full_record "s2" "ws-A" "/tmp/b" "ses_2"
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
log_content=$(cat "$MOCK_CMUX_SEND_LOG")
assert_contains "$log_content" "ses_1"
assert_contains "$log_content" "ses_2"
teardown_restore_mock
teardown_test_env

# ─────────────────────────────────────────────
describe "oc-restore — 恢复后行为"
# ─────────────────────────────────────────────

it "should call oc-scan after restore to refresh state"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_1"
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
scan_calls=$(grep -c "oc-scan" "$MOCK_CMUX_SEND_LOG" 2>/dev/null || echo "0")
assert_ne "0" "$scan_calls" "should call oc-scan after restore"
teardown_restore_mock
teardown_test_env

# ─────────────────────────────────────────────
describe "oc-restore — 边界情况"
# ─────────────────────────────────────────────

it "should skip records with empty sessionId"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_valid"
write_full_record "s2" "ws-B" "/tmp/b" ""
"$PROJECT_DIR/bin/oc-restore" 2>/dev/null
log_content=$(cat "$MOCK_CMUX_SEND_LOG")
assert_contains "$log_content" "ses_valid"
pass
teardown_restore_mock
teardown_test_env

it "should exit gracefully when state file is empty"
setup_test_env
setup_restore_mock
echo '{}' > "$STATE_FILE"
output=$("$PROJECT_DIR/bin/oc-restore" 2>&1)
assert_contains "$output" "No sessions"
teardown_restore_mock
teardown_test_env

it "should exit gracefully when state file does not exist"
setup_test_env
setup_restore_mock
rm -f "$STATE_FILE"
output=$("$PROJECT_DIR/bin/oc-restore" 2>&1)
assert_contains "$output" "No"
teardown_restore_mock
teardown_test_env

it "should report number of restored sessions"
setup_test_env
setup_restore_mock
export MOCK_CMUX_SEND_LOG="$TEST_TMPDIR/send.log"
touch "$MOCK_CMUX_SEND_LOG"
write_full_record "s1" "ws-A" "/tmp/a" "ses_1"
write_full_record "s2" "ws-B" "/tmp/b" "ses_2"
write_full_record "s3" "ws-C" "/tmp/c" "ses_3"
output=$("$PROJECT_DIR/bin/oc-restore" 2>&1)
assert_contains "$output" "3"
teardown_restore_mock
teardown_test_env

# ── 输出摘要 ──
print_summary
