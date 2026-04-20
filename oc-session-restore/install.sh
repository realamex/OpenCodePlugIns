#!/bin/bash
# install.sh — 安装 oc-session-restore
#
# 用法: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

# ── 检查依赖 ──
echo "Checking dependencies..."
for cmd in jq cmux opencode; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Please install it first."
    exit 1
  fi
done
log "All dependencies found."

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

# ── 1. oc-scan + oc-restore 命令 ──
for cmd in oc-scan oc-restore; do
  ln -sf "$SCRIPT_DIR/bin/$cmd" "$BIN_DIR/$cmd"
done
log "oc-scan, oc-restore linked to $BIN_DIR/"

if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
  warn "$BIN_DIR is not in PATH. Add to .zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 2. zsh 插件（opencode 退出时自动 scan） ──
ZSH_PLUGIN_DIR="$HOME/.local/share/zsh/plugins/oc-session-restore"
mkdir -p "$ZSH_PLUGIN_DIR"
ln -sf "$SCRIPT_DIR/oc-session-restore.plugin.zsh" "$ZSH_PLUGIN_DIR/oc-session-restore.plugin.zsh"
log "Zsh plugin linked to $ZSH_PLUGIN_DIR/"

ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ] && grep -qF "oc-session-restore.plugin.zsh" "$ZSHRC"; then
  log ".zshrc already has source line."
else
  echo "" >> "$ZSHRC"
  echo "# oc-session-restore: opencode 退出时自动快照会话" >> "$ZSHRC"
  echo "source \"$ZSH_PLUGIN_DIR/oc-session-restore.plugin.zsh\"" >> "$ZSHRC"
  log "Added source line to $ZSHRC"
fi

# ── 3. opencode 插件（session 切换时自动 scan） ──
OC_PLUGIN_DIR="$HOME/.config/opencode/plugins"
mkdir -p "$OC_PLUGIN_DIR"
ln -sf "$SCRIPT_DIR/plugin/session-tracker.js" "$OC_PLUGIN_DIR/session-tracker.js"
log "OpenCode plugin linked to $OC_PLUGIN_DIR/"

# ── 4. cmux 自定义命令 ──
CMUX_JSON="$HOME/.config/cmux/cmux.json"
mkdir -p "$(dirname "$CMUX_JSON")"
OC_SCAN_CMD="$HOME/.local/bin/oc-scan"
OC_RESTORE_CMD="$HOME/.local/bin/oc-restore"
# workspace 类型命令：任何分页下都能触发，自动创建新终端执行
NEW_CMDS="$(jq -n \
  --arg scan "$OC_SCAN_CMD" \
  --arg restore "$OC_RESTORE_CMD" '
[
  {
    name: "Scan OpenCode Sessions",
    keywords: ["scan","snapshot","oc"],
    workspace: {
      name: "OC Scan",
      layout: { pane: { surfaces: [{
        type: "terminal",
        command: ($scan + "; sleep 2; cmux close-workspace"),
        focus: true
      }]}}
    }
  },
  {
    name: "Restore OpenCode Sessions",
    keywords: ["restore","recover","oc"],
    workspace: {
      name: "OC Restore",
      layout: { pane: { surfaces: [{
        type: "terminal",
        command: $restore,
        focus: true
      }]}}
    }
  }
]')"
if [ -f "$CMUX_JSON" ]; then
  tmpfile=$(mktemp)
  jq --argjson new "$NEW_CMDS" '
    .commands = [.commands[]? | select(.name | (contains("Scan OpenCode") or contains("Restore OpenCode")) | not)] + $new
  ' "$CMUX_JSON" > "$tmpfile" && mv "$tmpfile" "$CMUX_JSON"
  log "Updated cmux.json with scan + restore commands (workspace type)"
else
  echo "{\"commands\":$NEW_CMDS}" | jq . > "$CMUX_JSON"
  log "Created cmux.json with scan + restore commands"
fi

# ── 5. state 目录 ──
mkdir -p "$HOME/.local/state/oc-session-restore"
log "State directory ready."

echo ""
echo "Done! Restart shell or: source ~/.zshrc"
echo ""
echo "Commands:"
echo "  oc-scan     Snapshot all current OpenCode sessions"
echo "  oc-restore  Restore sessions after cmux restart (or Cmd+P > Restore)"
