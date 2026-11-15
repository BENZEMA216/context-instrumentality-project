<p align="center"><img src="assets/eva-context-banner.png" alt="CONTEXT 补全计划 · The Context Instrumentality Project" width="100%" /></p>

# Context 补全计划 · The Context Instrumentality Project

> **研究如何把散落在物理世界与操作系统中的隐式个人上下文（Dark Context：线下语音、桌面剪切板、网页有效停留与正文、窗口焦点、AI 对话历史、移动端通知）捕获、对齐并安全地供给 AI Agent。**

当前本仓库定位为**研究型仓库与阅读学习索引**：系统归档我们在 **个人 Context 补全（Personal Context Completion）** 方向调研的开源项目、学术论文、评测基准、工程博客，以及本项目的专题研究文档与首批采集端代码。本地优先，开源推进中。

- **当前阶段**：M0（渠道可行性与跨源整合方法研究 · [RFC 0001](docs/rfc/0001-context-integration.md) 评审中 · [ROADMAP](ROADMAP.md)）
- **核心结论先行**：
  1. **摘要只用于导航，回答必须回溯原文**：*LifeDialBench* 与 *Chroma Context Rot* 均表明，过早有损压缩和上下文膨胀会伤害推理；应以 **append-only 原始事件流（L0）** 为唯一事实来源。
  2. **跨渠道对齐的主力单元是 Episode**：结合 **Promnesia 式锚点 Join**、**ActivityWatch 式时间区间求交 / Heartbeat 合并** 与 **EM-LLM 式事件边界切分**，把碎片行为缝合为完整工作情景。
  3. **时间有效性必须建模**：*STALE* 揭示了“隐式状态冲突”导致前沿模型掉点严重；事实与关系需要 **Graphiti 式双时间轴（`valid_at` / `invalid_at` + `created_at` / `expired_at`）**，关闭过期区间而非直接删历史。

---

## 目录导航

- [一、 本仓库专题研究归档](#一-本仓库专题研究归档internal-research-archive)
- [二、 开源项目分类索引](#二-开源项目分类索引open-source-projects)
- [三、 学术论文与评测基准索引](#三-学术论文与评测基准索引papers--benchmarks)
- [四、 技术博客、工程报告与系统规范](#四-技术博客工程报告与系统规范blogs-reports--specs)
- [五、 仓库结构与已接入采集端](#五-仓库结构与已接入采集端repository-structure--collectors)

---

## 一、 本仓库专题研究归档（Internal Research Archive）

| 文档 | 主题 | 核心内容 |
| :--- | :--- | :--- |
| [docs/research/channels.md](docs/research/channels.md) | **采集渠道可行性与优先级研究** | 拆解 12 个候选渠道的信号密度、OS 权限边界（macOS / Chrome MV3 / Android / iOS）、噪声过滤、注意力打分与阶段划分（M0 `R-01` / `R-03`–`R-05`） |
| [docs/research/integration-methods.md](docs/research/integration-methods.md) | **跨渠道整合方法与文献核实** | 11 个开源系统 Schema 深度对比、6 类整合策略权衡、论文/Benchmark 引用逐条核实与 5 层推荐架构（M0 `R-06` / `R-07`） |
| [docs/research/channel-audio.md](docs/research/channel-audio.md) | **语音渠道：`record-for-agent`** | 梳理 Watch → iPhone → Mac 本地 SQLite 录音库、分段转写数据模型、现有 MCP 接口与跨源整合缺口（M0 `R-02`） |
| [docs/research/channel-clipboard.md](docs/research/channel-clipboard.md) | **剪切板渠道：`ClipContext`** | 基于 Maccy 的用户授权快照 `clipboard.json`、`revision` + SHA-256 增量/撤销检测、只读 stdio MCP 工具及统一事件映射 |
| [docs/rfc/0001-context-integration.md](docs/rfc/0001-context-integration.md) | **RFC 0001：Context 整合方法提案** | 统一事件契约（配合 [schema/context-event.schema.json](schema/context-event.schema.json)）、L0–L4 分层架构、五级跨渠道链接、双时间轴与 MCP 暴露草案（`R-08`） |
| [docs/research/landscape.md](docs/research/landscape.md) | **早期全景调研初稿** | Dark Context 问题定义、端侧采集工程避坑指南与总体架构蓝图（早期初稿；核实后结论以上述正式报告为准） |

---

## 二、 开源项目分类索引（Open-Source Projects）

### 2.1 个人数据统一与时间线归档（Personal Data Unification & Timeline）

| 项目 | 核心机制 / Schema | 对本项目的关键启发 |
| :--- | :--- | :--- |
| [karlicoss/promnesia](https://github.com/karlicoss/promnesia) | `Visit(url, dt, context, locator)`；多数据源归一化 URL 汇总入 SQLite，浏览器侧边栏实时反查上下文 | **锚点 Join（URL 主键）+ `locator` 原文溯源**的经典范式 |
| [karlicoss/HPI](https://github.com/karlicoss/HPI) | *Human Programming Interface*：`my.*` Python 模块输出 typed iterator，`all.py` 聚合多来源 | 适合作为**采集适配层（DAL）**：先在各渠道内归一化为标准流，再跨渠道整合 |
| [timelinize/timelinize](https://github.com/timelinize/timelinize) | 本地 SQLite 四表模型（`items` + `entities` + `attributes` + `relationships`） | **统一时间线 + 实体关系图**双层模型；对话/地图等均为同一底表的投影视图 |
| [dogsheep](https://dogsheep.github.io/) | Simon Willison 发起的 SQLite + Datasette 个人数据仓库工具集 | 用极简本地 SQLite 表结构保留多服务原始导出并支持即时 SQL 检索 |

### 2.2 端侧感官与桌面 / 浏览器采集（Edge & OS Collectors）

| 项目 | 涵盖领域与机制 | 对本项目的关键启发 / 定位 |
| :--- | :--- | :--- |
| [ActivityWatch/activitywatch](https://github.com/ActivityWatch/activitywatch)<br>（[aw-watcher-window](https://github.com/ActivityWatch/aw-watcher-window) · [aw-watcher-web](https://github.com/ActivityWatch/aw-watcher-web)） | 隐私优先窗口/浏览器停留追踪；`bucket` + `event{timestamp, duration, data}` | **Heartbeat 合并（`pulsetime` 窗口延长）**、AFK 裁剪与跨 Bucket 区间求交原语可直接复用 |
| [p0deje/Maccy](https://github.com/p0deje/Maccy) | macOS 原生轻量剪切板管理器（MIT） | `NSPasteboard.general.changeCount` 轮询与 `ConcealedType` / `TransientType` 密码过滤参考实现（`ClipContext` 底座） |
| [kepano/defuddle](https://github.com/kepano/defuddle) · [obsidianmd/obsidian-clipper](https://github.com/obsidianmd/obsidian-clipper) | 现代网页正文抽取为 Markdown（保留代码、公式、脚注）+ 文本高亮器 | 替代传统 [mozilla/readability](https://github.com/mozilla/readability) 作为浏览器渠道正文抽取主力（Readability 作 fallback） |
| [WorldBrain/Memex](https://github.com/WorldBrain/Memex) | 浏览器全文历史索引与持久化高亮批注 | 网页选中高亮锚定（参考 W3C Web Annotation TextQuote 思路）与全文检索交互参考 |
| [BasedHardware/omi](https://github.com/BasedHardware/omi) | 开源穿戴式 AI 硬件 + 环境对话记忆平台 | 语音渠道工程参考：**`Conversation` 分段转写 → 结构化摘要 → 独立原子 `Memories`** 三层处理 |
| [screenpipe/screenpipe](https://github.com/screenpipe/screenpipe) · [openrecall/openrecall](https://github.com/openrecall/openrecall) | 24/7 本地桌面录屏 OCR + 音频转录 + SQLite FTS5 + MCP（`localhost:3030`） | **高开销对照组**：全量捕获证明“原始流 + FTS + MCP”可行，但缺语义整合且商业/AGPL 许可限制代码复用 |
| [atuinsh/atuin](https://github.com/atuinsh/atuin) | Shell 命令历史增强工具（SQLite 存 `cwd`、`exit_code`、`duration`、`session`） | 面向开发者的低成本高信号补充渠道，可直接读取其本地数据库 |
| [Freika/dawarich](https://github.com/Freika/dawarich) | 自托管个人位置轨迹与时间线（Google Timeline 开源替代） | 为线下音频与日程提供低功耗空间轨迹锚点 |
| [modelscope/FunASR](https://github.com/modelscope/FunASR) · [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice) · [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 本地端到端 ASR、VAD 切片与声纹说话人分离（CAM++ / pyannote） | 解决录音渠道中英混杂转写、静音剔除与“谁在说话（Self vs Others）”关键瓶颈 |

### 2.3 Agent 记忆与 Context 基础设施（Agent Memory & Context DB）

| 项目 | 核心架构 / 存储范式 | 对本项目的关键启发 |
| :--- | :--- | :--- |
| [volcengine/OpenViking](https://github.com/volcengine/OpenViking) | `viking://` 虚拟文件系统；每个目录提供 **L0（`.abstract.md`）/ L1（`.overview.md`）/ L2（原文）** | **分层摘要 + 按需渐进加载**，兼顾 Agent Token 预算、人机可读性与检索轨迹可观察性 |
| [getzep/graphiti](https://github.com/getzep/graphiti) | 实时时序知识图谱（Episode / Entity / Community 子图 + **双时间轴边**） | 时间有效性与状态冲突处理标准做法：新事实覆盖时关闭旧边 `invalid_at`，保留完整演变链 |
| [mem0ai/mem0](https://github.com/mem0ai/mem0)<br>（[mem0-chrome-extension](https://github.com/mem0ai/mem0-chrome-extension)） | 两阶段候选事实抽取 + LLM 决策 `ADD / UPDATE / DELETE / NOOP` | 事实写路径简洁；但直接 `DELETE` 会丢失历史与溯源，提醒我们原始层不可删除 |
| [letta-ai/letta](https://github.com/letta-ai/letta) | 原 MemGPT：Core Blocks + Recall + Archival 分层记忆，配合 **Sleep-time Agent** | 可借鉴后台 Sleep-time Agent 机制，离线异步计算跨渠道 Episode 与摘要 |
| [topoteretes/cognee](https://github.com/topoteretes/cognee) | `add → cognify → memify` ECL 流水线 + Pydantic `DataPoint` 节点建模 + 图/向量混合检索 | 可用强类型 `DataPoint` 统一表达 `Episode`、`WebPage`、`ClipboardItem` 等异构节点 |

### 2.4 主动式个人上下文与“第二大脑”应用（Proactive & Second-Brain Apps）

| 项目 | 定位与特点 | 参考价值 |
| :--- | :--- | :--- |
| [volcengine/MineContext](https://github.com/volcengine/MineContext) | 基于 Context Engineering 的主动式桌面 AI 伙伴 | 面向主动提示与日常脉络总结（类似 ChatGPT Pulse）的产品形态参考 |
| [khoj-ai/khoj](https://github.com/khoj-ai/khoj) | 自托管开源“AI 第二大脑”（本地笔记、文档与网页 RAG） | 多源静态文档索引与本地 LLM 问答体验参考 |
| [mindverse/Second-Me](https://github.com/mindverse/Second-Me) | 基于分层记忆与微调的个人数字分身训练框架 | 探讨长期个人记忆如何进一步内化为个性化模型表征 |
| [marswangyang/personal-ai-memory](https://github.com/marswangyang/personal-ai-memory) | 纯浏览器端 WebAssembly + IndexedDB 本地记忆图谱插件 | 浏览器内 **BM25 + 向量混合检索（Hybrid RAG）** 零后端实现范例 |
| [robzolkos/web-recap](https://github.com/robzolkos/web-recap) · [swetas7/Reading-Watch-List-Extension-Local-LLM](https://github.com/swetas7/Reading-Watch-List-Extension-Local-LLM) | 跨浏览器历史导出为 AI 就绪 JSON 与本地 LLM 页面摘要扩展 | 轻量级浏览历史清洗与摘要触发脚本参考 |

---

## 三、 学术论文与评测基准索引（Papers & Benchmarks）

### 3.1 连续生活流（Lifelog）与 Agent 长期记忆评测（2024–2026）

| 论文 / Benchmark | 链接 | 年份 / 会议 | 核心发现与对本项目的指导意义 |
| :--- | :--- | :--- | :--- |
| **LifeDialBench**: Evaluating Memory Capability in Continuous Lifelog Scenario | [arXiv:2604.11182](https://arxiv.org/abs/2604.11182) | 2026 | 引入 *EgoMem* / *LifeMem* 与**严格时间因果的在线流式评测**；发现**复杂摘要型记忆系统经常打不过保留原文的简单 RAG 基线**，证明有损压缩有害、原文证据不可丢弃 |
| **STALE**: Can LLM Agents Know When Their Memories Are No Longer Valid? | [arXiv:2605.06527](https://arxiv.org/abs/2605.06527) | 2026 | 聚焦**隐式冲突**（新观察悄悄推翻旧状态而无显式否定）；400 场景评测下最佳模型准确率仅 **55.2%**，提出写入时状态裁决与传播感知检索（CUPMem） |
| **PM-Bench**: Evaluating Prospective Memory in LLM Agents | [arXiv:2607.12385](https://arxiv.org/abs/2607.12385) · [Code](https://github.com/genglinliu/PMBench) | 2026 | 评估**前瞻记忆**（未来正确时刻/情境线索出现时主动触发未完成意图）；7 天模拟最佳 F1 约 65.1% |
| **MemoryCD**: Benchmarking Long-Context User Memory for Lifelong Cross-Domain Personalization | [arXiv:2603.25973](https://arxiv.org/abs/2603.25973) | 2026 | 基于多年真实用户多领域行为轨评估长期个性化与注意力加权利用 |
| **From Memory to Action**: Benchmarking Long-Term Agent Memory in Personal Assistant Environments | [OpenReview](https://openreview.net/) | 2026 | 拆解 Formation → Availability → Application → Outcome 四阶段，指出**最大性能掉点发生在“记忆已经可用 → 转化为正确动作”之间** |
| **LongMemEval**: Benchmarking Chat Assistants on Long-Term Interactive Memory | [arXiv:2410.10813](https://arxiv.org/abs/2410.10813) | ICLR 2025 | 涵盖五类长记忆能力（信息抽取、多会话推理、时间推理、知识更新、拒答），提出会话分解与时间感知 Query 扩展 |
| **LoCoMo**: Evaluating Very Long-Term Conversational Memory of LLM Agents | [arXiv:2402.17753](https://arxiv.org/abs/2402.17753) | 2024 | 超长多会话对话记忆基准（~300 轮 / ~9k token / 最多 35 会话），覆盖问答、事件摘要与多模态生成 |

### 3.2 事件分割、情景记忆与系统综述（Episodic Memory & Architectures）

| 论文 | 链接 | 年份 / 会议 | 核心机制与借鉴点 |
| :--- | :--- | :--- | :--- |
| **EM-LLM**: Human-like Episodic Memory for Infinite Context LLMs | [arXiv:2407.09450](https://arxiv.org/abs/2407.09450) | ICLR 2025 | 用 **Bayesian Surprise（预测误差突增）** 在线切分事件并做图论边界精修；两步检索（相似度召回 + 时间邻接扩展）可直接用于跨模态检索 |
| **Episodic Memory is the Missing Piece for Long-Term LLM Agents** | [arXiv:2502.06975](https://arxiv.org/abs/2502.06975) | 2025 | Position paper：明确定义情景记忆的五个核心性质——单次学习、情境特异（who/when/where）、时间组织、灵活检索与持续累积 |
| **Zep**: A Temporal Knowledge Graph Architecture for Agent Memory | [arXiv:2501.13956](https://arxiv.org/abs/2501.13956) | 2025 | Graphiti 引擎对应的论文架构，系统阐述 Episode / Entity / Community 三层子图与双时间轴边模型 |
| **Mem0**: Building Production-Ready AI Agents with Scalable Long-Term Memory | [arXiv:2504.19413](https://arxiv.org/abs/2504.19413) | 2025 | 提出两阶段事实抽取/更新管线及图扩展版 Mem0g，对比不同记忆压缩策略的延迟与召回权衡 |
| **Nemori**: Adaptive Memory Distillation（标题与 ID 对应关系部分核实） | [arXiv:2508.03341](https://arxiv.org/abs/2508.03341) | 2025 | 受事件分割理论启发对连续对话做 Episode 切分，并通过 predict-calibrate 从预测误差提炼语义知识 |
| **Memory for Autonomous LLM Agents**: Mechanisms, Evaluation, and Emerging Frontiers | [arXiv:2603.07670](https://arxiv.org/abs/2603.07670) | 2026 | 权威综述：用 POMDP 形式化 **Write–Manage–Read** 循环，按时间范围、表示载体与控制策略三轴归类现有系统 |

### 3.3 经典奠基文献（Lifelogging, Cognitive Theory & PKG）

| 文献 | 链接 / 出处 | 年份 | 核心思想 |
| :--- | :--- | :--- | :--- |
| **Personal Knowledge Graphs: A Research Agenda**（Balog & Kenter） | [DOI:10.1145/3341981.3344241](https://doi.org/10.1145/3341981.3344241) · [DBLP](https://dblp.org/rec/conf/ictir/BalogK19) | ICTIR 2019 | 定义关注个人私有实体（同事、项目、日常事件）的知识图谱构建、表示、使用与隐私保护议程 |
| **Event Segmentation Theory (EST)**（Zacks et al.） | *Psychological Bulletin*, 133(2):273–293 | 2007 | 认知科学理论基石：人脑持续预测下一刻感知输入，在**预测误差突增**的切换点划定事件边界并强化记忆编码 |
| **MyLifeBits**（Gemmell, Bell et al.）& **Lifelog Search Challenge (LSC)** | *CACM* 49(1), 2006 · [lifelogsearch.org](http://lifelogsearch.org/) | 2006–至今 | 个人全量数字记忆库先驱与国际检索评测挑战赛，验证了“**以 Event 为检索单元 + 前后时间邻接浏览**”的有效性 |

---

## 四、 技术博客、工程报告与系统规范（Blogs, Reports & Specs）

| 类型 | 标题与来源 | 链接 | 核心洞见 |
| :--- | :--- | :--- | :--- |
| **工程规范** | **Effective context engineering for AI agents**（Anthropic） | [anthropic.com](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | 将 Context 视为有限注意力预算；主张 **Just-in-Time 按需检索**（先给轻量路径/标识，需时再拉全文）、Compaction 与子 Agent 隔离 |
| **技术报告** | **Context Rot: How Increasing Input Tokens Impacts LLM Performance**（Chroma） | [research.trychroma.com/context-rot](https://research.trychroma.com/context-rot) | 实测 18 个模型，证明远未达窗口上限时模型性能就会随输入长度增加而退化——直接支撑本项目的 **L0/L1/L2 分级按需暴露** |
| **个人基建博客** | **HPI / Promnesia / Exobrain 系列实践**（Karlicoss） | [beepb00p.xyz](https://beepb00p.xyz/) | 探讨如何用“人类编程接口（HPI）”和本地自动化工具构建“扩展心智（Extended Mind）”，不依赖云厂商实现个人数据主权 |
| **数据仓库实践** | **Personal Data Warehouses: Reclaiming Your Data**（Simon Willison） | [simonwillison.net](https://simonwillison.net/2020/Nov/14/personal-data-warehouses/) | 提出用开源采集器 + 本地 SQLite（Dogsheep）收回散落各平台的个人数据并统一查询 |
| **macOS 隐私规范** | **nspasteboard.org 标记约定** | [nspasteboard.org](http://nspasteboard.org/) | 桌面剪切板采集隐私底线：跳过密码管理器写入的 `ConcealedType` / `TransientType` / `AutoGeneratedType` |
| **OS / 浏览器 API 文档** | **macOS Pasteboard Privacy（15.4+）** / **Chrome `idle` & Page Visibility** | [NSPasteboard Docs](https://developer.apple.com/documentation/appkit/nspasteboard) · [Michael Tsai](https://mjtsai.com/blog/) · [Chrome `idle`](https://developer.chrome.com/docs/extensions/reference/api/idle) · [Page Visibility](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API) | 规范化实现“允许访问提示控制（`accessBehavior` / `detect*`）”与“焦点 + 可见性 + Idle”三层有效网页停留时长计算 |

---

## 五、 仓库结构与已接入采集端（Repository Structure & Collectors）

```text
channels/            各渠道采集实现与研究
  audio/             语音：record-for-agent（Watch → iPhone → Mac 本地录音库）
  clipboard/         剪切板：ClipContext（基于 Maccy + Agent 共享快照/MCP）
  browser/           浏览器有效停留时长 + Defuddle 正文抽取（规划中）
  ai-chat/           AI 对话历史解析（规划中）
  window/            窗口焦点时间线（规划中）
schema/              统一事件模型契约（context-event.schema.json）
hub/                 本地跨源整合 + MCP 出口（规划中）
docs/research/       专题研究归档（channels / integration-methods / channel-*）
docs/rfc/            架构与整合方法设计提案（RFC 0001）
project/ scripts/    GitHub Milestones / Issues 规划与批量导入脚本
```

### 项目协作与许可证
- 路线图与里程碑：[ROADMAP.md](ROADMAP.md) · 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md) · 看板导入：[docs/github-projects-setup.md](docs/github-projects-setup.md)
- 许可证：待定（仓库内各子项目目前沿用各自许可证，开源整合前统一确认）。
