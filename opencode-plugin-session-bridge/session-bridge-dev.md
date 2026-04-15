# Session Bridge Plugin — 设计与开发记录

## 目标

在 OpenCode 中实现跨会话内容读取：让用户可以在当前 session 中查看其他 session 的对话内容，内容放入输入框供用户编辑后再提交给 AI。

核心要求：
- **零 AI 消耗**：读取操作本身不触发 AI 调用，不消耗 token
- **不污染上下文**：不向任何 session 注入消息
- **人工掌控**：内容放入输入框，用户编辑后自行决定是否提交

---

## 方案选型历程

### 方案 1：Custom Tool + appendPrompt

用 Custom Tool 实现，LLM 调用 tool → tool 读取消息 → appendPrompt 放入输入框。

**问题**：Custom Tool 需要 LLM 调用才能执行，每次至少消耗一轮 AI 对话（tool call + tool result + AI response），约 50-100 tokens。

### 方案 2：自定义命令（/peek）

用 `.opencode/commands/peek.md` 定义 slash command。

**问题**：OpenCode 的自定义命令**始终**将展开后的模板发送给 AI，无法绕过。即使模板内容为空或只有一个点，参数也会被追加发送。实测确认：模板设为 `.`，执行 `/peek auth重构` 后 AI 收到 `. auth重构`。

### 方案 3（最终）：Plugin + command.execute.before + throw

利用 Plugin 的 `command.execute.before` 钩子拦截命令，在 Plugin 中完成所有工作后 `throw` 阻断命令管线。

**关键发现**：
- `output.parts = []` 无法阻止命令发送给 AI（模板展开和 output.parts 是独立的）
- `throw new Error()` 可以完全阻断命令管线，AI 不会收到任何内容
- throw 的错误信息在 TUI 中不可见（不会显示给用户）
- 因此所有反馈（成功/错误）必须通过 `appendPrompt` 输出到输入框

---

## 架构

```
用户输入 /peek auth重构
    ↓
OpenCode 命令系统识别 /peek 命令
    ↓
触发 command.execute.before 钩子
    ↓
Plugin 拦截：
  1. 解析参数
  2. client.session.list() 查找目标 session
  3. client.session.messages() 读取消息
  4. 分组为 turns、筛选、格式化
  5. client.tui.appendPrompt() 输出到输入框
  6. throw new Error("peek") 阻断命令管线
    ↓
命令管线被阻断，AI 不会收到任何内容
用户在输入框中看到对话内容，可编辑后提交
```

### 文件结构

```
~/.config/opencode/
├── commands/
│   └── peek.md              # 命令定义（极简，仅作为入口）
└── plugins/
    └── session-bridge.ts     # Plugin 核心逻辑
```

`peek.md` 的模板内容无关紧要（因为 throw 会阻断），但必须存在以让 `/peek` 成为合法命令。

---

## 关键设计决策

### 1. 参数解析策略

**问题**：会话名可能含空格（如 "前端 开发"），与数字参数和过滤模式混在一起难以区分。

**方案**：从尾部开始，只消费**确实匹配已知值**的 token：

```
1. 最后一个 token 是合法过滤模式（all/answer/question）→ 消费
2. （新的）最后一个 token 是纯数字 → 消费为 count
3. 最后一个 token 既非过滤也非数字：
   a. 倒数第二个是纯数字 → 用户在过滤位置写了非法值 → 报错
   b. 否则不消费，视为会话名的一部分
4. 剩余全部 token join(" ") 为会话名
```

另外支持中英文双引号包裹会话名：`/peek "前端 开发" 3 all`

### 2. Turn 分组

**问题**：`session.messages()` 返回的是原始 message 列表。一次 AI 回答在 TUI 中看起来是连续的一段，底层可能是多条 message（文本 + tool call + 文本）。用户说"拿最近 1 条 AI 回答"时，期望拿到完整的一轮回答。

**方案**：将连续同角色的 message 分组为 "turn"（轮次），所有过滤、计数、格式化都以 turn 为单位。

```
原始消息：user, assistant, assistant, assistant, user, assistant, assistant
分组：     [user] [assistant×3] [user] [assistant×2]
```

### 3. 空消息跳过

**问题**：纯 tool call 的 message 没有 `type === "text"` 的 part，extractText 返回空字符串。如果这条消息被计入 count，用户看到的是空行。

**方案**：在 turn 层面过滤——一个 turn 内所有 message 的文本拼接后为空才跳过。这比逐条过滤更合理，因为一个 turn 中间可能有空 message（tool call），但前后有文本。

### 4. Markdown 清除

**问题**：AI 回答中的 markdown 格式（标题、加粗、代码块等）在输入框中显示为原始标记，影响阅读。

**方案演进**：
1. 最初用正则替换（约 15 条 regex），覆盖不全，嵌套格式处理不好
2. 考虑引入 npm 包（remove-markdown），但增加了依赖
3. 最终使用 **Bun.markdown.render()** + identity callbacks：Bun 内置 Zig 实现的 GFM 解析器，通过自定义回调让每种元素只返回纯文本

```typescript
Bun.markdown.render(text, {
  heading: children => children + "\n",
  strong: children => children,    // 去掉 ** 标记
  code: children => children + "\n", // 去掉 ``` 围栏
  // ...
})
```

零依赖，正式的 AST 解析，覆盖所有 GFM 格式。

### 5. /peek 无参数的暗示设计

无参数时不是列出 session 列表，而是直接生成一条可执行的完整命令：

```
/peek 跨会话模型交互可行性 1 answer
```

用户看到后：
- 可以直接回车执行（最省事）
- 可以修改数字（改成 3）
- 可以修改过滤模式（改成 all）
- 自然地知道了有什么参数可以用

### 6. 输出排序与序号

多轮消息从老到新排序（时间正序），但序号倒序（最新的 = 1）：

```
[ 3/3  AI说：]     ← 最老，距今第 3 轮
...
[ 1/3  AI说：]     ← 最新，距今第 1 轮
```

这样最新的消息在最下面（靠近输入框光标），便于阅读和编辑。

---

## 开发中遇到的坑

### 坑 1：output.parts = [] 无法阻止 AI 调用

**现象**：在 `command.execute.before` 中设置 `output.parts = []`，命令模板和参数仍然发送给了 AI。

**原因**：OpenCode 命令系统中，模板展开产生的主体文本和 `output.parts` 是独立的。`output.parts` 只能控制附加的 message parts，不能阻止模板文本的发送。

**解决**：改用 `throw` 完全阻断命令管线。

### 坑 2：throw 的错误信息在 TUI 中不可见

**现象**：`throw new Error("已获取对话内容到输入框")` 成功阻断了 AI 调用，但用户在界面上看不到任何反馈。

**原因**：`command.execute.before` 中 throw 的错误被 OpenCode 内部捕获并静默处理，不会显示给用户。

**解决**：所有反馈（成功/错误）通过 `appendPrompt` 输出到输入框，throw 仅用于阻断。

### 坑 3：命令模板会追加参数

**现象**：peek.md 模板设为 `.`，执行 `/peek auth重构` 后 AI 收到 `. auth重构`，而不是只有 `.`。

**原因**：OpenCode 命令系统会将用户输入的参数追加到模板展开结果后面，即使模板中没有 `$ARGUMENTS`。

**影响**：无法通过调整模板来控制 AI 收到的内容，只能用 throw 阻断。

### 坑 4：tui.appendPrompt() 只作用于当前 TUI 焦点

**现象**：`tui.appendPrompt()` 没有 `sessionId` 参数，只能写入 TUI 当前显示的 session。

**影响**：无法跨 session 写入输入框。最初设想的"A 写入 B 的输入框"不可行。

**解决**：改为纯 pull 模式——用户在当前 session 中主动拉取，appendPrompt 自然写入当前 session。

### 坑 5：单文本参数被误解析为过滤模式

**现象**：`/peek auth重构` 报错"无效过滤模式 auth重构"。

**原因**：初版参数解析无条件尝试将最后一个 token 当过滤模式消费。只有一个 token 时，会话名被当作过滤模式。

**解决**：改为只在 token 确实匹配已知值时才消费，不匹配则保留为会话名。

### 坑 6：消息条数与 TUI 显示不一致

**现象**：`/peek auth重构 1` 只拿到一条 message 的文本片段，而 TUI 中这只是完整回答的一部分。

**原因**：一次 AI 回答可能对应多条 message（文本 → tool call → 文本），`messages()` 返回的是原始 message 列表。

**解决**：引入 "turn" 概念，将连续同角色的 message 分组，count 改为"轮次"而非"条数"。

### 坑 7：纯工具调用消息产生空输出

**现象**：`/peek auth重构 2` 拿到 2 条结果，但有一条是空的。

**原因**：某些 assistant message 只有 tool call part，没有 text part。extractText 返回空字符串但仍计入 count。

**解决**：在 turn 层面过滤空文本。一个 turn 内所有 message 拼接后为空才跳过。

---

## API 依赖

| API | 用途 | 文档 |
|-----|------|------|
| `client.session.list()` | 列出所有 session | [SDK docs](https://opencode.ai/docs/sdk/) |
| `client.session.messages()` | 读取 session 消息 | [SDK docs](https://opencode.ai/docs/sdk/) |
| `client.tui.appendPrompt()` | 写入 TUI 输入框 | [Server docs](https://opencode.ai/docs/server/) |
| `client.tui.showToast()` | （已弃用）显示 toast | [Server docs](https://opencode.ai/docs/server/) |
| `Bun.markdown.render()` | Markdown 转纯文本 | [Bun docs](https://bun.sh/docs/runtime/markdown) |
| `command.execute.before` hook | 拦截命令 | [Plugin docs](https://opencode.ai/docs/plugins/) |

### Session 对象关键字段

```typescript
{
  id: string          // 30 字符，格式 ses_xxxx
  title: string       // 会话标题
  parentID?: string   // 子会话才有，用于排除 subagent 临时会话
  time: {
    updated: number   // Unix ms，用于排序
  }
}
```

### Message 对象关键字段

```typescript
{
  info: {
    role: "user" | "assistant" | "system" | "tool"
  },
  parts: [
    { type: "text", text: string },
    { type: "tool-invocation", ... },
    // ...
  ]
}
```
