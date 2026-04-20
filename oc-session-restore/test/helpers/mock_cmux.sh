#!/bin/bash
# test/helpers/mock_cmux.sh — cmux CLI mock
#
# 通过环境变量控制 mock 行为
# 将 MOCK_DIR 加入 PATH 前端覆盖真实 cmux

MOCK_DIR=""

setup_cmux_mock() {
  MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cmux-mock.XXXXXX")

  # ── mock cmux 命令 ──
  cat > "$MOCK_DIR/cmux" << 'CMUX_MOCK'
#!/bin/bash
case "$1" in
  tree)
    if [ -n "$MOCK_CMUX_TREE_JSON" ]; then
      echo "$MOCK_CMUX_TREE_JSON"
    else
      echo '{"windows":[]}'
    fi
    ;;
  read-screen)
    # 根据 --workspace 参数返回对应的 mock 屏幕内容
    ws=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --workspace) ws="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # 环境变量名: MOCK_CMUX_READSCREEN_WS1 对应 workspace:1
    varname="MOCK_CMUX_READSCREEN_$(echo "$ws" | tr ':' '_' | tr '[:lower:]' '[:upper:]')"
    eval "content=\"\${$varname:-}\""
    [ -n "$content" ] && echo "$content" || echo ""
    ;;
  new-workspace)
    echo "new-workspace $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"
    echo "OK workspace:99"
    ;;
  new-split)
    echo "new-split $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"
    echo "OK surface:99 workspace:99"
    ;;
  close-workspace)
    echo "OK $2"
    ;;
  send)
    echo "send $@" >> "${MOCK_CMUX_SEND_LOG:-/dev/null}"
    ;;
  *)
    echo "mock: unknown command $1" >&2
    ;;
esac
CMUX_MOCK
  chmod +x "$MOCK_DIR/cmux"

  export PATH="$MOCK_DIR:$PATH"
}

teardown_cmux_mock() {
  [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
}
