# OC Session Restore — 安装使用指南

cmux 关闭后一键恢复所有 OpenCode 会话。

## 前置条件

- macOS
- [cmux](https://cmux.com/) 终端
- [OpenCode](https://opencode.ai/) CLI
- [jq](https://jqlang.github.io/jq/)（`brew install jq`）

## 安装

```bash
cd ~/dev/oc-session-restore   # 项目目录（路径可自定义）
bash install.sh
```

安装脚本会：
1. 将 `oc-scan` 和 `oc-restore` 链接到 `~/.local/bin/`
2. 在 cmux 命令面板注册三个命令
3. 创建 state 目录

## 使用

### 自动快照（推荐）

`Cmd+P` → 输入 `auto` → 选择 "Start Auto-Scan (background)"

这会开启一个后台标签页，每 60 秒自动快照所有 OpenCode 会话。**请保持该标签页开启**（可以 pin 住）。

标签页开启后无需其他操作——开关 opencode、切换 session 都会在下一个 60 秒周期被自动捕获。

### 手动快照

`Cmd+P` → 输入 `scan` → 选择 "Scan OpenCode Sessions"

立即执行一次全量快照，完成后自动关闭。也可在终端中执行 `oc-scan`。

### 恢复会话

cmux 关闭后重新打开：`Cmd+P` → 输入 `restore` → 选择 "Restore OpenCode Sessions"

恢复脚本会：
1. 为每个之前打开的 OpenCode 会话创建新的 cmux workspace
2. 自动启动 opencode 并进入对应会话
3. 轮询检测所有会话是否加载完毕（每秒一次，最多 30 秒）

**请勿在提示 "Safe to close" 之前关闭恢复窗口。**

也可在终端中执行 `oc-restore`。

## 工作原理

```
oc-scan:
  cmux tree --json --all → 找到所有 "OC |" 开头的 workspace
  cmux read-screen → 从 TUI 屏幕读取真实 session 标题
  opencode session list → 按标题匹配得到 session ID
  → 原子写入 state.json

oc-scan --periodic（Auto-Scan 模式）:
  同上，但连续两次结果一致且非空时才写入
  已写入过的不重复写入（避免无意义的磁盘操作）

oc-restore:
  读取 state.json → 按 workspace 分组 → cmux new-workspace → 启动 opencode
  → 轮询 oc-scan 直到全部会话重新捕获
```

## 文件位置

| 文件 | 路径 |
|------|------|
| State file | `~/.local/state/oc-session-restore/state.json` |
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

**restore 后轮询超时（30s 未全部捕获）**
- 部分 opencode 可能启动较慢（MCP server 连接等）
- 手动 Cmd+P → Scan 刷新

**Auto-Scan 标签页被关闭**
- 自动快照停止，重新 Cmd+P → Auto-Scan 即可
