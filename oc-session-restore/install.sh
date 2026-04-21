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

# ── 2. 清理旧版本残留 ──
rm -f "$HOME/.config/opencode/plugins/session-tracker.js" 2>/dev/null
rm -f "$HOME/.config/opencode/plugins/session-tracker.ts" 2>/dev/null
rm -f "$HOME/.local/share/zsh/plugins/oc-session-restore/oc-session-restore.plugin.zsh" 2>/dev/null
rm -f "$HOME/.local/bin/oc-scan-periodic" 2>/dev/null
# 卸载旧的 launchd agent（如果存在）
launchctl bootout "gui/$(id -u)/com.oc-session-restore.scan" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.oc-session-restore.scan.plist" 2>/dev/null

# ── 3. cmux 自定义命令 ──
CMUX_JSON="$HOME/.config/cmux/cmux.json"
mkdir -p "$(dirname "$CMUX_JSON")"
OC_SCAN_CMD="$HOME/.local/bin/oc-scan"
OC_RESTORE_CMD="$HOME/.local/bin/oc-restore"
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
  },
  {
    name: "Start Auto-Scan (background)",
    keywords: ["auto","autoscan","background","oc"],
    workspace: {
      name: "OC Auto-Scan",
      layout: { pane: { surfaces: [{
        type: "terminal",
        command: ("echo \"Auto-scan started. Scanning every 60s.\"; echo \"Keep this tab open (can be pinned).\"; echo \"\"; while true; do sleep 60; " + $scan + " --periodic 2>/dev/null && echo \"$(date +%H:%M) scanned\" || true; done"),
        focus: true
      }]}}
    }
  }
]')"
if [ -f "$CMUX_JSON" ]; then
  tmpfile=$(mktemp)
  jq --argjson new "$NEW_CMDS" '
    .commands = [.commands[]? | select(.name | (contains("Scan OpenCode") or contains("Restore OpenCode") or contains("Auto-Scan")) | not)] + $new
  ' "$CMUX_JSON" > "$tmpfile" && mv "$tmpfile" "$CMUX_JSON"
  log "Updated cmux.json with scan + restore + auto-scan commands"
else
  echo "{\"commands\":$NEW_CMDS}" | jq . > "$CMUX_JSON"
  log "Created cmux.json with scan + restore + auto-scan commands"
fi

# ── 4. state 目录 ──
mkdir -p "$HOME/.local/state/oc-session-restore"
log "State directory ready."

echo ""
echo "Done!"
echo ""
echo "Usage:"
echo "  Cmd+P > 'Auto-Scan' — start background scan (every 60s, keep tab open)"
echo "  Cmd+P > 'Scan'      — manual one-time snapshot"
echo "  Cmd+P > 'Restore'   — restore after cmux restart"
