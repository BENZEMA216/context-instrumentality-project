# Channels

| 渠道 | 目录 | 状态 |
| :--- | :--- | :--- |
| 语音 | [audio/record-for-agent](audio/record-for-agent) | 已有实现 |
| 剪切板 | [clipboard/clipcontext](clipboard/clipcontext) | 已有实现 |
| 微信 | [wechat](wechat) | 历史会话文件导入、macOS 前台会话 OCR、本地定期导出 |
| 浏览器 | [browser](browser) | 规划中 |
| AI 对话历史 | [ai-chat](ai-chat) | 规划中 |
| 窗口焦点 | [window](window) | 规划中 |

每个渠道最终输出 [统一事件](../schema/context-event.schema.json)。可行性研究见 [docs/research/channels.md](../docs/research/channels.md)。
