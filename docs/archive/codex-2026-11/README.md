# Codex 阶段遗留资产归档（2026-11）

本目录记录 2026-11-23 仓库重整与 v2 重架构前，Codex 阶段产出的历史验收记录与分支归档索引。

## Git 归档标签索引

原 10 个长期未合并的叠罗汉/分叉 PR 已关闭，27 个冗余远端分支已清理；其完整提交历史已通过带注释的 Git 标签永久保留在仓库中：

| Git 标签 | 原 PR / 分支 | 保留内容与 v2 处置方式 |
| :--- | :--- | :--- |
| `archive/codex-pr2-hub` | PR #2 (`feat/1-context-engine`) | 第一版 Hub（正则摘要、`instr()` 检索、基础管理页与 10 工具 CRUD MCP）→ **v2 全面重构**（L0-L4 + FTS5 + Agent-as-Curator + 高层 MCP + Workbench） |
| `archive/codex-pr4-vault` | PR #4 (`feat/3-context-vault`) | 独立单文件加密库 + HPKE 手机投递 + 发现 CLI → **v2 吸收 HPKE 投递与发现设计，重构为逐条加密 + 实用型代理与 CLI 注入并融合进主工作台** |
| `archive/codex-pr6-persom` | PR #6 (`codex/research-persom-200`) | Persom 0.1.200 深度逆向调研与复现实验 → **已合入 `docs/research/persom-0.1.200.md`** |
| `archive/codex-pr8-wechat` | PR #8 (`codex/wechat-channel`) | WeFlow JSON 导入 + 单窗 4 坐标定时 OCR → **v2 保留 WeFlow 解析器，重构采集为 macOS AX 优先 + 自适应 OCR 多会话监听** |
| `archive/codex-pr13-history` | PR #13 (`codex/agent-conversation-history`) | 10 端 AI 对话日志解析与离线导出器 → **核心解析器在 Phase 2 吸收重构并升级为后台增量采集** |
| `archive/codex-pr24-recording-icloud` | PR #18–#24 五层录音/iCloud 栈 | 录音回执与 iCloud 占位清单读取经验 → **在 Phase 3 统一收敛到 `collectors/audio` + `sherpa-onnx`/`SenseVoice` 本地转写管线** |

## 历史验收文档

- [2026-11-22-source-to-agent.md](2026-11-22-source-to-agent.md)
- [2026-11-22-chat-history.md](2026-11-22-chat-history.md)
