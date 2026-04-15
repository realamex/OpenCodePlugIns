import type { Plugin } from "@opencode-ai/plugin"

/**
 * Session Bridge Plugin
 *
 * 拦截 /peek 命令，读取其他 session 的最近对话并放入输入框。
 * Plugin 在 command.execute.before 阶段完成所有工作，
 * 然后 throw 阻断命令管线，阻止内容发送给 AI（零 token 消耗）。
 * 所有反馈（成功/错误）统一通过 appendPrompt 输出到输入框。
 *
 * 消息以"轮次（turn）"为单位——连续同角色的消息合并为一轮，
 * 与 TUI 中看到的对话结构一致。
 *
 * 用法:
 *   /peek                              自动填充: /peek <最近会话名> 1 answer
 *   /peek <数字>                        列出最近 N 个会话（上限 10，最新在最下面）
 *   /peek <会话名>                      获取指定会话最近 1 轮 AI 回答
 *   /peek <会话名> <数字>               获取指定会话最近 N 轮 AI 回答
 *   /peek <会话名> <数字> all           获取最近 N 轮完整对话
 *   /peek <会话名> <数字> question      获取最近 N 轮用户提问
 *   /peek <会话名> <数字> answer        获取最近 N 轮 AI 回答（默认）
 *   /peek "含空格的会话名" <数字>        用引号包裹含空格的会话名（支持中英文引号）
 */

// ─── 类型 ───

const VALID_FILTERS = ["all", "answer", "question"] as const
type Filter = (typeof VALID_FILTERS)[number]

/** 一轮对话：连续同角色的消息合并 */
interface Turn {
  role: "user" | "assistant"
  messages: any[]
}

// ─── Plugin ───

export const SessionBridge: Plugin = async ({ client }) => {
  // ─── 工具函数 ───

  /** appendPrompt 后 throw 阻断 AI */
  async function done(text: string): never {
    try {
      await client.tui.appendPrompt({ body: { text } })
    } catch {
      // 静默跳过
    }
    throw new Error("peek")
  }

  /** 获取非当前、非子 session 列表，按 time.updated 升序（最新在最后） */
  async function getOtherSessions(currentId: string) {
    const res = await client.session.list()
    const all = res.data ?? []
    return all
      .filter((s: any) => s.id !== currentId && !s.parentID)
      .sort((a: any, b: any) => (a.time?.updated ?? 0) - (b.time?.updated ?? 0))
  }

  /**
   * 解析参数。
   *
   * 策略：从尾部只消费**确实匹配**已知值的 token，剩余全部视为会话名。
   * 1. 最后一个 token 是合法过滤模式 → 消费为 filter
   * 2. （新的）最后一个 token 是纯数字 → 消费为 count
   * 3. 最后一个 token 既非过滤也非数字：
   *    a. 倒数第二个是纯数字 → 用户在过滤位置写了非法值 → 报错
   *    b. 否则不消费，视为会话名的一部分
   * 4. 剩余 tokens join(" ") 为会话名
   *
   * 支持引号包裹含空格的会话名（"" "" 「」）。
   */
  function parseArgs(raw: string): {
    name?: string
    count: number
    filter: Filter
    error?: string
  } {
    if (!raw) return { count: 1, filter: "answer" }

    // 提取引号包裹的会话名
    const quoteRe = /^[""\u201c\u201d\u300c\u300d](.+?)[""\u201c\u201d\u300c\u300d]\s*(.*)/
    const quoteMatch = raw.match(quoteRe)
    let quotedName: string | undefined
    let rest: string

    if (quoteMatch) {
      quotedName = quoteMatch[1]
      rest = quoteMatch[2].trim()
    } else {
      rest = raw
    }

    const tokens = rest ? rest.split(/\s+/) : []
    let filter: Filter = "answer"
    let count = 1
    let filterError: string | undefined

    if (tokens.length) {
      const last = tokens[tokens.length - 1]

      if (VALID_FILTERS.includes(last.toLowerCase() as Filter)) {
        // 最后一个 token 是合法过滤模式
        filter = tokens.pop()!.toLowerCase() as Filter

        // 检查新的最后一个 token 是否是数字
        if (tokens.length && /^\d+$/.test(tokens[tokens.length - 1])) {
          count = Math.min(Math.max(parseInt(tokens.pop()!), 1), 20)
        }
      } else if (/^\d+$/.test(last)) {
        // 最后一个 token 是纯数字
        count = Math.min(Math.max(parseInt(tokens.pop()!), 1), 20)
      } else {
        // 最后一个 token 既非过滤也非数字
        // 检查倒数第二个是否是数字（说明最后一个在过滤模式位置，但非法）
        if (tokens.length >= 2 && /^\d+$/.test(tokens[tokens.length - 2])) {
          const bad = tokens.pop()!
          count = Math.min(Math.max(parseInt(tokens.pop()!), 1), 20)
          filterError = `[/peek 无效过滤模式 "${bad}"，可选: all/answer/question]`
        }
        // 否则：所有 tokens 都是会话名的一部分，不消费
      }
    }

    const name = quotedName ?? (tokens.length ? tokens.join(" ") : undefined)
    return { name, count, filter, error: filterError }
  }

  /** 将消息列表分组为 turns（连续同角色消息合并） */
  function groupIntoTurns(msgs: any[]): Turn[] {
    const turns: Turn[] = []
    for (const m of msgs) {
      const role: "user" | "assistant" = m.info?.role === "user" ? "user" : "assistant"
      const last = turns[turns.length - 1]
      if (last && last.role === role) {
        last.messages.push(m)
      } else {
        turns.push({ role, messages: [m] })
      }
    }
    return turns
  }

  /** 按过滤模式筛选 turns，排除无有效文本的 turn */
  function filterTurns(turns: Turn[], filter: Filter): Turn[] {
    let result = turns
    if (filter === "answer") result = result.filter((t) => t.role === "assistant")
    else if (filter === "question") result = result.filter((t) => t.role === "user")
    return result.filter((t) => extractTurnText(t).trim().length > 0)
  }

  /** 从一个 turn 的所有消息中提取并拼接文本 */
  function extractTurnText(turn: Turn): string {
    const parts: string[] = []
    for (const m of turn.messages) {
      const text = (m.parts ?? [])
        .filter((p: any) => p.type === "text")
        .map((p: any) => p.text ?? "")
        .join("")
      if (text.trim()) parts.push(text)
    }
    return stripMarkdown(parts.join("\n\n"))
  }

  /** 用 Bun 内置 markdown 解析器将 markdown 转为纯文本（零依赖） */
  function stripMarkdown(text: string): string {
    try {
      return Bun.markdown.render(text, {
        heading: (children: string) => children + "\n",
        paragraph: (children: string) => children + "\n",
        strong: (children: string) => children,
        emphasis: (children: string) => children,
        link: (children: string) => children,
        image: () => "",
        code: (children: string) => children + "\n",
        codespan: (children: string) => children,
        strikethrough: (children: string) => children,
        blockquote: (children: string) => children,
        list: (children: string) => children,
        listItem: (children: string) => children.trimEnd() + "\n",
        hr: () => "",
        html: () => "",
        table: (children: string) => children,
        thead: (children: string) => children,
        tbody: (children: string) => children,
        tr: (children: string) => children.trimEnd() + "\n",
        th: (children: string) => children + " | ",
        td: (children: string) => children + " | ",
      }).replace(/\n{3,}/g, "\n\n").trim()
    } catch {
      return text
    }
  }

  /** 格式化 turn 列表 */
  function formatTurns(turns: Turn[]): string {
    const total = turns.length

    // 单轮：纯文本，无 header
    if (total === 1) return extractTurnText(turns[0])

    // 多轮：[ N/M  AI说：] 分隔，序号倒序（最新 = 1），内容从老到新
    return turns
      .map((t, i) => {
        const seq = total - i
        const role = t.role === "user" ? "用户说：" : "AI说："
        const text = extractTurnText(t)
        return `[ ${seq}/${total}  ${role}]\n${text}`
      })
      .join("\n\n")
  }

  // ─── 主逻辑 ───

  return {
    "command.execute.before": async (input, output) => {
      if (input.command !== "peek") return

      const raw = (input.arguments ?? "").trim()
      const currentId = input.sessionID ?? ""
      const parsed = parseArgs(raw)

      if (parsed.error) await done(parsed.error)

      let others: any[]
      try {
        others = await getOtherSessions(currentId)
      } catch {
        await done("[/peek 错误] 获取 session 列表失败")
      }

      // --- 无参数: 自动填充最近一个 session ---
      if (!raw) {
        if (!others!.length) await done("[/peek] 无其他可用 session")
        const latest = others![others!.length - 1]
        await done(`/peek ${latest.title || latest.id} 1 answer`)
      }

      // --- 无会话名: 列出 session 或检查纯数字会话名 ---
      if (!parsed.name) {
        const exactMatch = [...others!].reverse().find((s: any) => s.title === raw.trim())
        if (exactMatch) {
          parsed.name = raw.trim()
          parsed.count = 1
        } else {
          const n = Math.min(parsed.count, 10)
          if (!others!.length) await done("[/peek] 无其他可用 session")
          const recent = others!.slice(-n)
          const lines = recent.map((s: any) => `/peek ${s.title || s.id}`)
          await done(lines.join("\n"))
        }
      }

      const keyword = parsed.name!

      // 匹配（优先最新的）
      const reversed = [...others!].reverse()
      const target =
        reversed.find((s: any) => s.title === keyword) ??
        reversed.find((s: any) => s.title?.includes(keyword)) ??
        reversed.find((s: any) => s.id.startsWith(keyword))

      if (!target) {
        if (others!.length) {
          const suggestions = others!
            .slice(-3)
            .map((s: any) => `/peek ${s.title || s.id}`)
            .join("\n")
          await done(`[/peek 未找到 "${keyword}"，试试:]\n${suggestions}`)
        }
        await done(`[/peek 未找到 "${keyword}"，试试 /peek 查看可用 session]`)
      }

      // 读取消息
      let allMsgs: any[]
      try {
        const msgs = await client.session.messages({ path: { id: target.id } })
        allMsgs = msgs.data ?? []
      } catch {
        await done(`[/peek 错误] 读取 session "${target.title}" 失败`)
      }

      // 分组为 turns → 筛选 → 取末尾 count 轮
      const turns = groupIntoTurns(allMsgs!)
      const filtered = filterTurns(turns, parsed.filter)
      const recent = filtered.slice(-parsed.count)

      if (!recent.length) {
        await done(`[/peek] Session "${target.title}" 暂无匹配消息`)
      }

      await done(formatTurns(recent))
    },
  }
}
