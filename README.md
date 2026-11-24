<p align="center">
  <img src="assets/eva-context-banner.png" alt="Raw Memory · Context 补全计划" width="100%" />
</p>

# Raw Memory · Personal Raw Data & Evidence-Gated Memory Engine

**Local-first 个人原始数据与证据门控记忆引擎（[`rawmemory.app`](https://rawmemory.app) · [`github.com/rawmemory`](https://github.com/rawmemory)）**：把你在 **AI 会话、剪贴板（`Clip for Agent`）、录音（`Record for Agent`）、浏览器（`Read for Agent`）、聊天（`Chat for Agent`）、窗口焦点（`Focus for Agent`）与加密私密库（`Vault for Agent`）** 中散落的真实数字生活沉淀为不可变 `L0` 原档、`L1` 毫秒级混合 BM25 索引与跨源链接、`L2` 人机共读 Markdown 档案、`Project Profiles` 项目静态档案与 `L3` 双时序决策台账。

通过 **Agent-as-Curator** 整理闭环、**公开 Benchmark（LongMemEval / LoCoMo）**、**Reflexive Meta Benchmark（RFC-0003）** 与 **Human-in-the-Loop 本地调试台（`raw-memory-eval workbench`）**，确保**原始数据真实可靠、记忆产出零脑补抗噪音、全程可观测可回溯**。

> **核心原则**：
> 1. **零内置云端密钥**：引擎不捆绑付费模型 API，通过 MCP + Skill 复用你已有的 Agent 算力（Antigravity / Codex / Claude Code / WorkBuddy）执行离线整理。
> 2. **存“真相指针”，不存“瞬时外部状态”**：项目静态身份、仓库与实时状态查询入口归入 `Project Profile`，瞬时 Build/PR 快照绝不污染长期个人记忆。
> 3. **一问一答强溯源**：每条决策与记忆都绑定真实 `evidence_ids`，Agent 对话证据自动带出 `±1` 轮问答上下文窗口，并经过 Claim-to-Evidence 忠实度与 Anti-Noise 门禁校验。

---

## 架构一览

详细设计见 **[RFC-0002：Raw Memory & Agent-as-Curator](docs/rfc/0002-hub-v2-agent-curator.md)** 与 **[RFC-0003：Reflexive Meta Memory Benchmark](docs/rfc/0003-meta-memory-benchmark.md)**。

```text
X for Agent 采集矩阵
  ├─ AI Sessions (11 端, No-Echo 防回环)     ├─ Record for Agent (iOS/Watch + SenseVoice 本地转写)
  ├─ Clip for Agent (macOS 剪贴板, PNG 无损)  ├─ Read for Agent (Chrome/Arc/Safari + MV3 扩展)
  ├─ Focus for Agent (macOS 焦点 / AW 桥接)   ├─ Chat for Agent (WeFlow / WeChat / Telegram 合规导入)
  └─ Vault for Agent (AES-256-GCM 隔离加密库 → 仅同步脱敏指针回执)
                       │
                       ▼
Raw Memory 引擎: L0 raw/ (不可变原档) + L0.5 blobs/
              ──► L1 hub.sqlite3 (SQLite WAL + CJK/EN Hybrid BM25 + Episode↔Turn RRF + 跨源链接)
              ──► Project Profiles (项目静态档案 & Live Status Pointers)
              ──► L2 Episodes + markdown/ (MEMORY.md / projects / daily)
              ──► L3 Bi-Temporal Decisions & Personal Memories (支持 supersede / retract / Q&A 证据窗)
              ──► L4 MCP Server (`raw-memory mcp`) + Meta Eval & Debug Workbench (`raw-memory-eval`)
```

---

## `X for Agent` 产品家族与模块状态

| 渠道 / 模块 | 产品名 | 形态 / 路径 | 状态 | 核心能力 |
| :--- | :--- | :--- | :---: | :--- |
| 🧠 后端引擎 | **`Raw Memory`** | [`packages/hub/`](packages/hub/README.md) · `raw-memory` | ✅ 运行中 | L0–L4 存储、混合 BM25+RRF 检索、`Project Profiles`、一问一答证据窗、双时序决策、MCP Server |
| 📊 评测与调试 | **`Raw Memory Eval`** | [`packages/eval/`](benchmarks/README.md) · `raw-memory-eval` | ✅ 运行中 | **LoCoMo / LongMemEval-S / Oracle** 公开基准 + RFC-0003 反身性基准 + Claim 忠实度/Anti-Noise 门禁 + **本地人工裁决调试台** |
| 🤖 AI 会话 | **`ai_chat` Collector** | [`packages/collectors/.../ai_chat/`](packages/collectors/src/context_collectors/ai_chat/) | ✅ 已落地 | 11 端增量断点续传（Antigravity / Codex / Claude / Cursor / OpenCode 等）+ No-Echo 剥离 + 信号预标注 |
| 🎙️ 录音 | **[`Record for Agent`](https://github.com/rawmemory/record-for-agent)** | iOS / watchOS + [`audio/`](packages/collectors/src/context_collectors/audio/) | ✅ 已落地 | Watch/iPhone 录音 + 本地 `SenseVoice-Small` / `Silero-VAD` 离线转写 + [`record-for-agent-skill`](https://github.com/rawmemory/record-for-agent-skill) |
| 📋 剪贴板 | **[`Clip for Agent`](https://github.com/rawmemory/ClipContext)** | macOS App + [`clipcontext.py`](packages/collectors/src/context_collectors/clipcontext.py) | ✅ 已落地 | 无损 PNG 压缩防 TIFF 膨胀 + 正式开发签名 + `org.chromium.source-url` 锚点 + 撤销同步 |
| 🌐 浏览器 | **`Read for Agent`** | [`browser.py`](packages/collectors/src/context_collectors/browser.py) + [`extensions/browser/`](extensions/browser/README.md) | ✅ 已落地 | Chrome/Arc/Brave/Edge/Safari 无锁增量历史采集 + 敏感域隐私隔离 + MV3 三层停留/Defuddle 扩展 |
| 🖥️ 窗口焦点 | **`Focus for Agent`** | [`window.py`](packages/collectors/src/context_collectors/window.py) | ✅ 已落地 | 原生 macOS 零依赖前台窗口采集 + ActivityWatch 桥接 + 停留聚类 + 密码管理器/无痕窗口拦截 |
| 💬 聊天 | **`Chat for Agent`** | [`chat.py`](packages/collectors/src/context_collectors/chat.py) | ✅ 核心已落地 | WeFlow / WeChat / Telegram / CSV 合规导入 + **默认 `local_only` 隐私隔离** + 白名单项目群放行 |
| 🔐 私密库 | **`Vault for Agent`** | [`packages/vault/`](packages/vault/README.md) · `raw-vault` | ✅ 核心已落地 | 逐条 **AES-256-GCM** 加密 SQLite 孤岛 + `raw-vault run` 零暴露环境变量注入与输出脱敏 + 脱敏回执同步 |

---

## 公开 Memory Benchmark 实测（纯本地 SQLite FTS5，零 Embedding API、零 GPU）

详细方法论、按维度拆解与复现命令见 **[`benchmarks/README.md`](benchmarks/README.md)**：

| Benchmark 套件 | 规模 | `v0.2.0` 旧引擎 | **`v0.3.0` Hybrid BM25 + RRF** | p50 延迟 |
| :--- | :--- | ---: | ---: | ---: |
| **[LongMemEval-S](benchmarks/results/longmemeval_s.md)** (ICLR 2025) | 500 题 × ~48 会话 (246,750 轮) | Sess R@5 `3.2%` / Turn R@5 `0.0%` | **Sess R@5 `96.6%` · R@10 `98.5%` · Turn R@5 `77.0%`** | `1.93 ms` |
| **[LongMemEval-Oracle](benchmarks/results/longmemeval_oracle.md)** (ICLR 2025) | 500 题（证据会话精确定位） | Sess R@5 `3.2%` / Turn R@5 `0.0%` | **Sess R@1 `100.0%` · Turn R@5 `84.3%` · R@10 `93.0%`** | `0.64 ms` |
| **[LoCoMo Curated](benchmarks/results/locomo10_curated.md)** (ACL 2024) | 10 场长对话 (1,986 QA) | R@5 `0.1%` / R@10 `0.1%` | **R@5 `61.3%` · R@10 `72.5%` · All-R@10 `61.5%`** | `2.04 ms` |
| **[Reflexive Meta](benchmarks/results/reflexive_meta.md)** (RFC-0003) | 18 因果隔离案例 + 5 代防回声 | — | **Recall `100.0%` · Stale `0.0%` · 5-Gen Anti-Echo PASS** | `3.45 ms` |

---

## 快速开始（Quickstart）

```bash
# 1. 安装依赖（Python 3.12 + uv）
uv sync --extra dev

# 2. 检查本机 6 大采集通道可用性（只读，不修改任何数据）
uv run raw-collectors doctor --collector all --since-days 7

# 3. 增量同步指定通道（例如 AI 对话 / 剪贴板 / 浏览器 / 窗口焦点）
uv run raw-collectors sync --collector ai_chat --since-days 30
uv run raw-collectors sync --collector clipcontext
uv run raw-collectors sync --collector browser --since-days 7

# 4. 校验 Raw Data 就绪度、Memory 质量与压缩忠实度
uv run raw-memory-eval audit-raw
uv run raw-memory-eval audit-memory
uv run raw-memory-eval inspect-fidelity

# 5. 启动 Human-in-the-Loop 本地调试台（压缩人工裁决 + 项目档案 + 实时检索调试 + 错题本）
uv run raw-memory-eval workbench --port 8765

# 6. 运行公开 Benchmark（LoCoMo / LongMemEval-S）
uv run raw-memory-eval bench download --suite all
uv run raw-memory-eval bench run --suite longmemeval-s

# 7. 初始化 Vault for Agent 加密私密库并安全注入密钥执行命令
uv run raw-vault init
uv run raw-vault set --kind api_key --label "Example Key" --allow-cmd curl
uv run raw-vault sync-receipts
```

---

## 导航索引

- **架构与协议**：[RFC-0002 (Raw Memory & Agent-as-Curator)](docs/rfc/0002-hub-v2-agent-curator.md) · [RFC-0003 (Reflexive Meta Memory Benchmark)](docs/rfc/0003-meta-memory-benchmark.md) · [RFC-0001](docs/rfc/0001-context-integration.md) · [事件 Schema](schema/context-event.schema.json) · [Roadmap](ROADMAP.md)
- **评测与基准**：[Benchmark 总览与复现](benchmarks/README.md) · [Curator v2.1 整理规范](skills/context-curator/SKILL.md)
- **子包与扩展**：[Raw Memory Hub](packages/hub/README.md) · [Vault for Agent](packages/vault/README.md) · [Read for Agent MV3 扩展](extensions/browser/README.md) · [Agent 插件包](plugins/context-hub/README.md) · [通道目录](channels/README.md)
- **研究工作台**：[研究总索引](docs/research/README.md) · [开源项目精读 (28)](docs/research/projects-digest.md) · [论文与博客精读 (22)](docs/research/papers-blogs-digest.md)
- **协作与归档**：[AGENTS.md](AGENTS.md) · [CONTRIBUTING.md](CONTRIBUTING.md)
