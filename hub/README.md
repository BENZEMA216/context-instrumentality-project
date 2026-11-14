# Hub（规划中）

本地跨渠道整合层（原始事件 → 链接 → Episode），通过 MCP 提供给 Agent。设计见 [RFC 0001](../docs/rfc/0001-context-integration.md)。

不重复造单渠道轮子：
- **语音**：读取 `record-for-agent` 的 `AgentBridge` 本地库与 `recordings.available` 事件；
- **剪切板**：读取 `ClipContext` 的共享快照 `clipboard.json`（及 `revision`/指纹增量）。
