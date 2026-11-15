<p align="center"><img src="assets/eva-context-banner.png" alt="CONTEXT 补全计划 · The Context Instrumentality Project" width="100%" /></p>

# Context 补全计划 · Context Instrumentality Project

把 Agent 原本拿不到的个人 Context（语音、剪切板、浏览、AI 对话……）补给它。本地优先，开源。

> 状态：早期。已并入语音（`record-for-agent`）和剪切板（`ClipContext`）两套现有采集端；跨渠道整合方法在评审中（[RFC 0001](docs/rfc/0001-context-integration.md)）。

## 结构

```
channels/            各渠道采集
  audio/             语音：record-for-agent（Watch → iPhone → Mac）
  clipboard/         剪切板：ClipContext（基于 Maccy + Agent 共享快照/MCP）
  browser/           浏览停留时长 + 正文（规划中）
  ai-chat/           AI 对话历史（规划中）
  window/            窗口焦点时间线（规划中）
schema/              统一事件模型
hub/                 本地整合 + MCP 出口（规划中）
docs/research/       渠道与整合方法研究
docs/rfc/            设计提案
project/ scripts/    GitHub Issues / Projects 导入
```

## 文档

- [ROADMAP](ROADMAP.md) · [贡献指南](CONTRIBUTING.md)
- 研究：[渠道总览](docs/research/channels.md) · [语音渠道](docs/research/channel-audio.md) · [剪切板渠道](docs/research/channel-clipboard.md) · [整合方法](docs/research/integration-methods.md)

## 许可证

待定（仓库内各子项目目前沿用各自许可证，开源前统一确认）。
