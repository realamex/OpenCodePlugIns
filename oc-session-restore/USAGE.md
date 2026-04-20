# OC Session Restore — 安装使用指南

cmux 关闭后一键恢复所有 OpenCode 会话。

## 前置条件

- macOS
- [cmux](https://cmux.com/) 终端
- [OpenCode](https://opencode.ai/) CLI
- [jq](https://jqlang.github.io/jq/)（`brew install jq`）

## 安装

```bash
cd ~/dev/oc-session-restore   # 项目目录
bash install.sh
```

安装脚本会：
1. 将 `oc-scan` 和 `oc-restore` 链接到 `~/.local/bin/`
2. 安装 zsh 插件（opencode 退出时自动快照）
3. 安装 opencode 插件（session 切换时自动快照）
4. 在 cmux 命令面板注册 "Restore OpenCode Sessions"

安装后重启 shell：
```bash
source ~/.zshrc
```

## 日常使用

**日常无需任何操作。** 以下事件会自动触发快照：
- 退出 opencode → zsh 钩子自动后台执行 `oc-scan`
- 在 opencode 中切换 session → opencode 插件自动后台执行 `oc-scan`

也可以随时手动执行：
```bash
oc-scan          # 立即快照所有 OpenCode 会话
oc-scan --quiet  # 静默模式
```

## 恢复会话

cmux 关闭后重新打开，执行：

```bash
oc-restore
```

或在 cmux 中按 `Cmd+P` → 输入 `restore` → 选择 "Restore OpenCode Sessions"。
（Cmd+P 命令在任何分页下都可触发，包括非终端标签页。）

恢复脚本会为每个之前打开的 OpenCode 会话创建新的 cmux workspace 并自动启动 opencode 进入对应会话。同一个 workspace 中的分屏也会被重建。

恢复完成后会自动轮询检测所有会话是否加载完毕，请勿在提示 "Safe to close" 之前关闭恢复窗口。

## 工作原理

```
oc-scan 全量快照:
  cmux read-screen → 从每个 OpenCode TUI 屏幕读取 session 标题
  opencode session list → 按标题匹配得到 session ID
  ps eww → 获取 cmux surface/workspace UUID
  → 原子写入 state.json

oc-restore 恢复:
  读取 state.json → 按 workspace 分组 → 创建 cmux workspace → 启动 opencode
  → 轮询 oc-scan（每秒一次，最多 30 次）直到全部会话重新捕获
```

## 文件位置

| 文件 | 路径 |
|------|------|
| State file | `~/.local/state/oc-session-restore/state.json` |
| zsh 插件 | `~/.local/share/zsh/plugins/oc-session-restore/` |
| opencode 插件 | `~/.config/opencode/plugins/session-tracker.js` |
| 命令 | `~/.local/bin/oc-scan`、`~/.local/bin/oc-restore` |

## 测试

```bash
cd ~/dev/oc-session-restore
bash test/run_all.sh
```

## 故障排查

**oc-scan 输出 "No OpenCode workspaces found"**
- 确认 cmux 中有以 "OC |" 开头的 workspace 标签

**某个会话显示 MISS**
- 该会话可能在 opencode 首页（未选择 session），或 session 标题在 `opencode session list` 中找不到
- 手动恢复：`opencode` → `/session` → 选择会话

**oc-restore 后 opencode 报错**
- session 数据仍在 opencode 的 SQLite 数据库中，不会因 cmux 关闭而丢失
- 直接 `opencode` → `/session` 手动进入即可
