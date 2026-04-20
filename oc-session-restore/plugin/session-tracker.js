// plugin/session-tracker.js — OpenCode 插件
//
// session 创建/切换时延迟 3 秒触发 oc-scan 全量快照
// 使用官方文档的事件名 key 格式 + Bun $ shell API

const OC_SCAN_PATH = `${process.env.HOME}/.local/bin/oc-scan`;

let scanTimer = null;

function triggerScan($) {
  if (scanTimer) clearTimeout(scanTimer);
  scanTimer = setTimeout(async () => {
    try {
      await $`${OC_SCAN_PATH} --quiet`;
    } catch {
      // scan 失败不影响 opencode 运行
    }
    scanTimer = null;
  }, 3000);
}

export const SessionTracker = async ({ $ }) => ({
  "session.created": async (input) => {
    triggerScan($);
  },
  "session.updated": async (input) => {
    triggerScan($);
  },
  "session.idle": async (input) => {
    // 对话结束、状态稳定时也 scan 一次
    triggerScan($);
  },
});
