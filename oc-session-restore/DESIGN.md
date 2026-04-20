# OC Session Restore — 设计文档

## 1. 目标

cmux 关闭（正常退出/崩溃/断电）后重新打开时，一键恢复所有之前正在运行的 OpenCode 会话。

## 2. 核心思路

**全量快照 + 事件驱动 + 原子写入。**

`oc-scan` 通过 `cmux read-screen` 直接从每个 OpenCode TUI 屏幕读取真实 session 标题，结合 `opencode session list` 匹配得到 session ID，实现 100% 准确的全量快照。

每次 scan 都是完整快照——已关闭的 opencode 天然不会出现在结果中，不需要增量追踪或清理逻辑。

## 3. 架构

```
事件触发（自动）:
  opencode 退出 (zsh precmd)    ──→ 后台 oc-scan ──→ state.json
  session 切换 (opencode 插件)  ──→ 3s 防抖 → 后台 oc-scan ──↗

手动（Cmd+P，任何分页下可触发）:
  oc-scan                       ──→ state.json
  oc-restore                    ←── state.json → 创建 workspace → 启动 opencode → 轮询 scan
```

## 4. 组件

### 4.1 oc-scan（核心）

全量快照当前 cmux 中所有 OpenCode 会话。

**数据获取链路：**

```
cmux tree --json --all
  → 筛选所有 window 中 "OC | " 开头的 workspace → 得到 ws_ref + tty

cmux read-screen --workspace <ws_ref>
  → 第 2 行右侧提取 session 标题（用 "Context" 行做列偏移锚点）

ps -eo pid=,comm= + ps eww
  → 通过 tty 关联 opencode PID → 读取 CMUX_SURFACE_ID / CMUX_WORKSPACE_ID

opencode session list --format json
  → 按 title 匹配 → 得到 session ID
```

**四级 Fallback 匹配：**

| 级别 | 方法 | 适用场景 |
|------|------|----------|
| 1 | read-screen 第 2 行右侧 → 精确匹配 | 大多数情况（~70%） |
| 2 | read-screen 第 2+3 行拼接 → 精确匹配 | 英文长标题换行 |
| 3 | workspace 标题 "OC \| xxx" → 精确匹配 | 左侧内容污染了 screen 提取 |
| 4 | contains 模糊匹配 | 极少数情况 |

实测 14 个 OpenCode workspace：**14/14 = 100% 命中**（12 个 Level 1/2，2 个 Level 3）。

**防重复执行：**

快速连续操作时（如连续切换 session），旧 scan 被 kill，新 scan 启动。数据写入是最后一步原子操作（先写 tmp，再 `mv` 到 state.json），被 kill 的 scan 不会留下脏数据。

```
1. 读 PID 文件 → kill 旧 scan（如果存在）
2. 写入自己的 PID
3. 扫描全部数据（cmux tree, read-screen, ps, session list）
4. 全部就绪 → 写入 tmp 文件
5. mv tmp → state.json（原子操作，此前被 kill 都安全）
6. 清除 PID 文件
```

### 4.2 oc-restore

读取 state.json，按 workspaceId 分组重建 workspace。

```
对每组:
  cmux new-workspace --cwd <cwd> --command "opencode --session <id>"
  同组内多个 surface（原来是分屏）→ cmux new-split + cmux send
轮询 oc-scan（每 1 秒一次，最多 30 次）直到全部会话被重新捕获
```

### 4.3 zsh 钩子（~25 行）

检测 opencode 退出 → 后台触发 `oc-scan --quiet`。

**不在 opencode 启动时 scan**：此刻 TUI 未渲染，屏幕上没有 session 数据。启动时 scan 无意义且可能与进程初始化冲突。

### 4.4 opencode 插件（~25 行）

检测 session 切换（`session.created` / `session.updated` 事件）→ 3 秒防抖后触发 `oc-scan --quiet`。

不自己操作 state file，完全委托 oc-scan。

## 5. State File

路径：`~/.local/state/oc-session-restore/state.json`

```json
{
  "<CMUX_SURFACE_UUID>": {
    "sessionId": "ses_...",
    "workspaceId": "<CMUX_WORKSPACE_UUID>",
    "cwd": "/path/to/dir"
  }
}
```

每次 scan 全量覆盖写入。无 `updatedAt`、无 TTL、无增量逻辑。

## 6. 事件流分析

| 场景 | 触发 | state.json 变化 |
|------|------|----------------|
| 用户退出 opencode | precmd → scan | 该会话从快照中消失 |
| 用户切换 session | 插件 → 3s 后 scan | 该 surface 的 sessionId 更新 |
| 用户关闭 cmux 标签 | 无触发（shell 被杀） | 保留上次 scan 的数据 |
| cmux 正常/异常关闭 | 无触发 | 保留，oc-restore 可用 |
| 快速连续操作 | 旧 scan 被 kill，新 scan 执行 | 写入最终最新状态 |
| 手动执行 oc-scan | 立即全量快照 | 完全覆盖 |

## 7. 风险与容错

| 风险 | 概率 | 后果 | 应对 |
|------|------|------|------|
| session 切换后 cmux 立即崩溃（3s 内） | 极低 | 恢复到切换前的 session | session 数据不丢失，手动切回 |
| 新开 opencode 后未触发过 scan | 低 | 该会话不在快照中 | 下次任意 opencode 退出/切换 session 时全量捕获 |
| read-screen 提取失败（窗口极窄） | 低 | 四级 fallback 处理 | 实测 100% 命中 |
| scan 被 kill | 正常 | 原子写入保护，无脏数据 | 设计如此 |

## 8. 技术细节

### read-screen 标题提取

OpenCode TUI 右侧面板固定显示 session 标题（第 2 行右侧），下方是 `Context` 行。即使用户改了 cmux workspace 名，TUI 中显示的仍然是真实 session 标题。

```
┌─ 左侧：对话内容 ──────────────────────────────┬─ 右侧面板 ─────────────┐
│  ┃  Thinking: ...                               │                        │
│  ┃  1. It avoids file I/O                       │ 网页UI转PSD性能优化方案 │ ← 第 2 行
│  ┃                                              │                        │
│  ┃  2. The raw pixel data stays in memory       │ Context                │ ← 锚点
│  ┃                                              │ 126,083 tokens         │
```

用 `Context` 行的列偏移确定右面板位置，`cut -c${start_col}-` 提取第 2 行右侧内容。

### 被排除的 session ID 获取方式

以下方式均已验证不可行，记录在此避免重复调研：

| 探测方式 | 结果 |
|----------|------|
| HTTP API (`opencode serve`) | TUI 模式不启动 HTTP server |
| 进程命令行 (`ps -o args`) | 绝大多数无参启动，session ID 不在参数里 |
| 环境变量 `OPENCODE_SESSION_ID` | PR #9289 未合并，不存在 |
| SQLite DB (`opencode.db`) | 无"当前活跃 session"字段，`workspace_id` 全为空 |
| 日志文件 (`~/.local/share/opencode/log/`) | 不含 session ID |
| 文件描述符 (`lsof`) | 所有 opencode 进程打开同一个 db，无法区分 |
| 进程内存 | 纯内存状态，无非侵入性读取方式 |

**唯一可行路径：`cmux read-screen` 读取 TUI 屏幕中显示的 session 标题。**

### 已知限制

1. **OpenCode 在首页（未选 session）**：TUI 右侧不显示 session 标题 → 跳过，不写入 state。
2. **重名 session**：取 `time_updated` 最近的那个。重名不常见，全部纳入恢复即可。
3. **窗口极窄**：左侧内容可能延伸到右面板区域 → Level 1 失败，fallback 到 Level 3。
4. **`opencode session list` 的 `-n` 限制**：极旧的 session 可能不在前 200 条中，可提高 `-n` 值。

## 9. 项目结构

```
oc-session-restore/
├── DESIGN.md                           # 本文档
├── USAGE.md                            # 安装使用指南
├── bin/
│   ├── oc-scan                         # 全量快照
│   └── oc-restore                      # 恢复脚本
├── lib/
│   └── state.sh                        # state file 路径定义
├── oc-session-restore.plugin.zsh       # zsh 钩子
├── plugin/
│   └── session-tracker.js              # opencode 插件
├── test/
│   ├── run_all.sh
│   ├── test_scan.sh                    # scan 测试（防重复 + 原子写入）
│   ├── test_restore.sh                 # restore 测试
│   └── helpers/
│       ├── setup.sh
│       └── mock_cmux.sh
└── install.sh                          # 安装脚本
```

## 10. 外部依赖

| 依赖 | 用途 | macOS 自带？ |
|------|------|:---:|
| `jq` | JSON 处理 | 否（`brew install jq`） |
| `cmux` CLI | workspace 操作 + read-screen | 是（cmux 内置） |
| `opencode` CLI | session 列表查询 | 需安装 |
| `ps` | 进程发现 + 环境变量读取 | 是 |
| `lsof` | 进程工作目录检测 | 是 |
