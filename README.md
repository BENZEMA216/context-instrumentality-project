<p align="center">
  <img src="assets/eva-context-banner.png" alt="CONTEXT 补全计划 · The Context Instrumentality Project" width="100%" />
</p>

# Context 补全计划 · The Context Instrumentality Project

**Local-first 个人上下文操作系统**：把你在 **AI 对话、剪贴板、浏览器、微信、录音、窗口焦点与私密资料库（Vault）** 中散落的真实数字生活沉淀为可追溯的 `L0` 原档、`L1` 毫秒级全文索引与跨源链接、`L2` 人机共读的 Markdown 档案与 `L3` 双时序决策台账，并通过 **Agent-as-Curator** 模式复用你已有的 Agent 算力（Antigravity / Codex / WorkBuddy / Claude Code）自动整理与按需召回。

> **核心理念**：Hub 本身不内置昂贵的外部模型密钥，也不靠脆弱正则伪装记忆——Hub 做最稳的确定性底座，把透明可编辑的**整理规则、待整理队列与强校验回写接口**通过 MCP & Skill 暴露给你正在使用的 Agent，零额外算力成本完成高质量记忆整理。

---

## 核心架构一览

详细设计见 **[RFC-0002：Context Hub v2 与 Agent-as-Curator](docs/rfc/0002-hub-v2-agent-curator.md)** 与 **[RFC-0001：跨渠道整合草案](docs/rfc/0001-context-integration.md)**。

```text
采集渠道 (AI Chat / ClipContext / Browser MV3 / WeChat / Record-for-Agent / Window / Location)
   │
   ▼
L0 raw/ (不可变原档) ──► L1 hub.sqlite (FTS5 中文检索 + 5 级跨源链接)
                              │
                              ▼
L2 Episodes + markdown/ (YAML Frontmatter 人机共读) ◄──► Agent-as-Curator
                              │                          (Antigravity / Codex / WorkBuddy)
                              ▼
L3 Bi-Temporal Decisions (当前定案 / superseded_by) ──► L4 高层 MCP Server + Workbench UI
                                                              ▲
Context Vault v2 (隔离逐条加密库 · 实用型授权代办) ───────────┘ (仅同步脱敏回执)
```

---

## 模块状态

| 模块 | 路径 | 当前状态 | 说明 |
| :--- | :--- | :---: | :--- |
| **Context Hub v2** | `packages/hub/` | 🚧 Phase 1 重构中 | L0–L4 引擎、FTS5、Agent-as-Curator 整理队列与强校验回写、双闭环 MCP |
| **Context Workbench UI** | `web/` | 🚧 Phase 1 重构中 | 统一时间线、项目决策面板、Markdown 预览、渠道与隐私策略管理 |
| **AI 对话历史** | `packages/collectors/` | ⏳ Phase 2 | 10+ AI 客户端增量采集（含 Codex / Claude / Cursor / Antigravity / ChatGPT 等） |
| **剪贴板（ClipContext）** | `packages/collectors/` | ⏳ Phase 2 | 自动增量监听独立 App `ClipContext` 归档，免手工导入 |
| **浏览器扩展（MV3）** | `extensions/browser/` | ⏳ Phase 2 | 三层有效停留 + Defuddle/Readability 转 Markdown + 无弹窗划词提权 + 上下文侧边栏 |
| **微信渠道** | `packages/collectors/` · `native/macos/` | ⏳ Phase 3 | WeFlow 合规历史导入 + macOS AX 优先 / 自适应 OCR 多会话监听 |
| **录音（Record for Agent）** | `packages/collectors/` | ⏳ Phase 3 | Mac/iCloud 自动增量接入 + `sherpa-onnx` + `SenseVoice-Small` 离线高精度转写 |
| **Context Vault v2** | `packages/vault/` | ⏳ Phase 4 | 逐条加密私密库 + Touch ID 解锁 + HPKE 手机扫描 + 实用型白名单代理与 CLI 注入 |

---

## 导航索引

- **架构与协议**：[RFC-0002 (Hub v2 & Agent-as-Curator)](docs/rfc/0002-hub-v2-agent-curator.md) · [RFC-0001](docs/rfc/0001-context-integration.md) · [事件 Schema](schema/context-event.schema.json) · [Roadmap](ROADMAP.md)
- **研究工作台（L1 / L2 / L3 全景调研）**：[研究总索引](docs/research/README.md) · [Google Sheet 在线筛选表](https://docs.google.com/spreadsheets/d/1ggWJjSIKsgY5Wro-GPciEo9AhJOD4gEi-DQv5uCHRbg/edit) · [开源项目精读 (28)](docs/research/projects-digest.md) · [论文与博客精读 (22)](docs/research/papers-blogs-digest.md) · [Persom 0.1.200 剖析](docs/research/persom-0.1.200.md)
- **专题调研**：[采集渠道对比](docs/research/channels.md) · [整合方法与架构](docs/research/integration-methods.md) · [启发与格式设计](docs/research/design-reflections.md) · [音频通道](docs/research/channel-audio.md) · [剪贴板通道](docs/research/channel-clipboard.md)
- **协作与归档**：[AGENTS.md](AGENTS.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [Codex 阶段归档索引](docs/archive/codex-2026-11/README.md)
