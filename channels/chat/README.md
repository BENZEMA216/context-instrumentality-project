# Chat for Agent · 合规聊天记录通道

实现位于 [`packages/collectors/src/context_collectors/chat.py`](../../packages/collectors/src/context_collectors/chat.py)（对应 [Issue #7](https://github.com/rawmemory/context-instrumentality-project/issues/7)）：

- **支持导出格式**：WeFlow 原生微信 JSON（含 `session.accountId` / `isGroup` / `replyTo`）、Telegram Desktop JSON、通用 JSONL 与 CSV。
- **默认最严隐私边界（Privacy-by-Default）**：所有导入会话默认标记为 `local_only`，绝不对 Agent 暴露私聊；仅当会话 ID 或群名显式加入 `~/.local/share/context-hub-v2/inbox/chat/chat_allowlist.json` 时，才按配置提升为 `shareable` / `redacted` 并自动归属对应项目。
- **命令**：
  - 投放导出文件至 `~/.local/share/context-hub-v2/inbox/chat/` 后执行：`uv run raw-collectors sync --collector chat`
  - 或单次手动导入：`uv run raw-collectors import-im --allowlist chat_allowlist.json export.json`
