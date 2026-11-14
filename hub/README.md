# Hub（规划中）

本地整合各渠道事件（原始事件 → 链接 → Episode），通过 MCP 提供给 Agent。设计见 [RFC 0001](../docs/rfc/0001-context-integration.md)。

语音不重复实现：读取 record-for-agent 的本地库与 `recordings.available` 事件。
