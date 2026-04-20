#!/bin/zsh
# oc-session-restore.plugin.zsh — 极简 zsh 钩子
#
# opencode 退出后自动触发 oc-scan 全量快照
# opencode 启动时不 scan（TUI 未渲染，屏幕无数据）

_OCR_TRACKING=""

_ocr_preexec() {
  [[ "$1" =~ ^opencode(\ |$) ]] || return
  [ -z "$CMUX_SURFACE_ID" ] && return
  _OCR_TRACKING=1
}

_ocr_precmd() {
  [ -z "$_OCR_TRACKING" ] && return
  _OCR_TRACKING=""
  # opencode 退出 → 后台全量快照（更新所有会话状态）
  oc-scan --quiet &>/dev/null &
  disown
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _ocr_preexec
add-zsh-hook precmd _ocr_precmd
