# 整合方法研究：已有系统、学术脉络与推荐架构（R-06 / R-07）

> **核实方式**：通过 web search 交叉比对，未能直接打开 arxiv.org。"已核实"表示多个搜索结果中的标题、ID、作者、摘要一致。Timelinize / Omi / screenpipe 的字段级 schema 来自文档与二手资料，写进正式文档前应对照源码再核对一次。

## 结论（TL;DR）

1. **六类整合策略各有所长，没有一种能单独胜任**：锚点 join（Promnesia）、统一事件日志（ActivityWatch）、Episode 分割（EM-LLM / Omi）、时序知识图谱（Graphiti）、LLM 事实抽取（Mem0）、分层摘要文件系统（OpenViking）。
2. **推荐采用五层架构**：原始事件日志 → 链接 → Episode → 实体/事实 → Agent 视图。只有原始层（L0）是事实来源，下游各层都可以从它重新计算出来。
3. **两个关键证据**：LifeDialBench 发现"复杂记忆系统经常打不过简单 RAG，有损压缩有害"；Chroma 的 Context Rot 报告显示"输入越长性能越差"。由此确定原则：**摘要只用于导航，回答时必须能回溯到原文。**
4. **跨渠道关联的主力机制是 Episode**，辅以从便宜到昂贵的五级链接计算：确定性锚点 → 内容指纹 → 时间结构 → 语义相似 → 融合打分。

---

## 1. 已有开源系统的数据模型

| 系统 | 核心 schema | 对我们的启示 |
| :--- | :--- | :--- |
| [Promnesia](https://github.com/karlicoss/promnesia) | `Visit(url, dt, context, locator)`，以归一化 URL 为键汇总进 SQLite | **锚点 join**；用 locator 承担溯源 |
| [HPI](https://github.com/karlicoss/HPI) | `my.*` 模块，每个模块输出 typed iterator，`all.py` 合并多个来源 | 适合做采集适配层：先在渠道内归一化 |
| [Timelinize](https://github.com/timelinize/timelinize) | `items`（带时间戳的数据点）+ `entities` + `attributes` + `relationships`；"对话"等视图从同一套底表投影出来 | **统一时间线 + 实体图**两层结构 |
| [ActivityWatch](https://github.com/ActivityWatch/activitywatch) | `bucket` + `event{timestamp, duration, data}`；**heartbeat 合并**（数据相同且在 pulsetime 窗口内，就只延长 duration）；跨 bucket 求区间交集 | 窗口和浏览停留时长可以直接照搬；区间求交是很便宜的时间对齐原语 |
| [screenpipe](https://github.com/mediar-ai/screenpipe) | SQLite：`frames` / `ocr_text` / `audio_transcriptions`（含 speaker_id）+ FTS5；MCP 通过本地 REST 访问 | "原始流 + 全文检索 + MCP" 的最小可行方案；缺少语义整合 |
| [OpenViking](https://github.com/volcengine/OpenViking) | `viking://` 虚拟文件系统；每个目录分三层：L0 `.abstract.md`（一句话）、L1 `.overview.md`（约 2k token）、L2 原文 | **分层摘要 + 按需加载**，符合 Agent 的 token 预算 |
| [Graphiti](https://github.com/getzep/graphiti)（[arXiv:2501.13956](https://arxiv.org/abs/2501.13956)） | Episode / Entity / Community 三类子图；边上带**双时间轴**（`valid_at/invalid_at` + `created_at/expired_at`），出现矛盾时关闭旧边的有效区间，而不是删除 | 时间有效性与冲突处理的标准做法 |
| [Mem0](https://github.com/mem0ai/mem0)（[arXiv:2504.19413](https://arxiv.org/abs/2504.19413)） | 先抽取候选事实，再由 LLM 选择 ADD / UPDATE / DELETE / NOOP | 写入路径简单；但 DELETE 会丢失历史，削弱溯源 |
| [Letta](https://github.com/letta-ai/letta) | core memory blocks + recall + archival；sleep-time agent 在后台异步整理 | 可以借用后台整理来离线计算 Episode |
| [cognee](https://github.com/topoteretes/cognee) | `add → cognify → memify`；用 `DataPoint` 自定义节点类型 | 可以把 WebPage、ClipboardItem 定义为节点类型 |
| [Omi](https://github.com/BasedHardware/omi) | `Conversation{started_at, finished_at, transcript_segments[{speaker,text,start,end}], structured{title, overview, action_items}}` + 独立的 Memories | 语音渠道的实践：会话切段 → 结构化摘要 → 事实，正好对应三层 |

## 2. 学术脉络

- **Lifelog 检索**：从 Memex 到 MyLifeBits，再到 NTCIR Lifelog 和 LSC。主流经验是**以事件为检索单元，并支持"之前/之后"这类时间邻接查询**。
- **事件分割与情景记忆**：
  - Event Segmentation Theory：在预测误差突增处划定事件边界。
  - [EM-LLM](https://arxiv.org/abs/2407.09450)（ICLR 2025）：用 Bayesian surprise 在线切分事件；检索时先按相似度找事件，再补上时间上相邻的事件。
  - [Episodic Memory is the Missing Piece](https://arxiv.org/abs/2502.06975)：提出情景记忆的五个性质。
  - Nemori（[arXiv:2508.03341](https://arxiv.org/abs/2508.03341)，标题与 ID 的对应关系只部分核实）。
- **个人知识图谱**：Balog & Kenter, *Personal Knowledge Graphs: A Research Agenda*, ICTIR 2019。
- **Context engineering**：
  - Anthropic《Effective context engineering for AI agents》主张 just-in-time 检索（先给轻量标识，按需再取），以及 compaction。
  - Chroma《Context Rot》：输入越长，模型性能越差，远未达到窗口上限时就开始下降。

### 前期调研引用的核实结果

| 名称 | 结论 | 出处 | 与本项目相关的要点 |
| :--- | :--- | :--- | :--- |
| LifeDialBench | ✅ 已核实 | [arXiv:2604.11182](https://arxiv.org/abs/2604.11182) | 采用在线流式评测；复杂记忆系统常常打不过简单 RAG，有损压缩有害 |
| STALE | ✅ 已核实 | [arXiv:2605.06527](https://arxiv.org/abs/2605.06527) | 隐式冲突：400 个场景、1200 个 query，最好成绩 55.2%；提出 CUPMem |
| PM-Bench | ✅ 已核实（ID 只在一组搜索结果中出现，建议人工确认） | [arXiv:2607.12385](https://arxiv.org/abs/2607.12385) | 前瞻记忆，7 天模拟，最好 F1 约 65.1% |
| MemoryCD | ✅ 已核实 | [arXiv:2603.25973](https://arxiv.org/abs/2603.25973) | 基于真实多年用户行为的跨域个性化 |
| Memory for Autonomous LLM Agents（综述） | ✅ 已核实 | [arXiv:2603.07670](https://arxiv.org/abs/2603.07670) | write–manage–read 循环；三轴分类 |
| From Memory to Action | ⚠️ 只有 OpenReview 条目，未找到 arXiv ID | OpenReview | **最大的掉点出现在"记忆已经可用"之后、"转化为动作"之前** |
| LongMemEval | ✅ 已核实 | [arXiv:2410.10813](https://arxiv.org/abs/2410.10813) | 五类能力；时间感知的 query 扩展 |
| LoCoMo | ✅ 已核实 | [arXiv:2402.17753](https://arxiv.org/abs/2402.17753) | 长对话记忆评测 |

## 3. 六类整合策略对比

| 策略 | 代表 | 优点 | 缺点 | 成本 | 溯源 | 时间有效性 | 跨模态关联 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| (a) 锚点 join | Promnesia | 确定、可解释、零 LLM 开销 | 只能关联有共同锚点的数据；语音通常没有 URL | 极低 | 极好 | 不处理 | 网页↔剪切板强，语音↔网页弱 |
| (b) 统一事件日志 | ActivityWatch、Timelinize | 是事实来源，可回放、可重算 | 本身没有语义 | 低 | 天然具备 | 数据不可变，不存在冲突 | 只能靠时间邻近 |
| (c) Episode 分割 | EM-LLM、Omi、LSC | 符合人类记忆；检索粒度合适 | 边界难定；跨天任务会被切碎 | 中 | 好 | 有时间范围，但不判断事实是否过时 | **主要的跨模态机制** |
| (d) 时序知识图谱 | Graphiti、cognee | 支持多跳推理；双时间轴 | 抽取有误差；难以维护 | 高 | 好 | 最好 | 通过共享实体关联 |
| (e) LLM 事实抽取 | Mem0、Letta | 紧凑，直接放进 prompt | 有损；DELETE 丢历史 | 中 | 弱 | 粗糙 | 弱 |
| (f) 分层摘要文件系统 | OpenViking | token 高效，人可读可改 | 摘要会过时 | 中 | 中 | 需要重建摘要 | 取决于目录组织方式 |

## 4. 推荐的分层架构（RFC 0001 的输入）

```text
L0 原始层  Raw Event Log：append-only，是事实来源；按渠道分 bucket，原文放 blob
   ↓ 确定性处理：归一化、heartbeat 合并、AFK 裁剪、URL 归一化、PII 标注
L1 链接层  Links：锚点 + 时间邻近 + 内容指纹 + embedding，带置信度与证据
   ↓
L2 情景层  Episodes：时间窗 + 上下文切换 + 语义连贯，记录成员事件，附 L0/L1 摘要
   ↓ 后台异步处理，可选
L3 语义层  Entities + Facts：双时间轴，每条带 source_event_ids，只增不删
   ↓
L4 视图层  MCP resources/tools，分 L0/L1/L2 渐进加载
```

### 跨渠道链接的计算（从便宜到昂贵）

1. **确定性锚点**：URL 归一化后精确匹配；文件路径、邮箱、电话等标识符精确匹配。
2. **内容指纹**：检测剪切板文本是否是网页正文的子串（MinHash），判为 `copy_of`。
3. **时间结构**：用区间求交，把剪切板事件定位到当时的前台窗口和标签页；在 ≤15 分钟、中间无 AFK 的窗口内给近邻打分，分数随时间指数衰减。
4. **语义相似**：embedding 相似度 + 实体重叠。
5. **融合打分**：先用规则或加权打分，有标注数据后再学习权重；超过阈值才建立链接，并保存证据。
6. **Episode 边界**：应用/项目切换、空闲超过阈值、语义漂移三者组合判断；后台再用 LLM 精修边界并生成摘要。

### MCP 暴露（草案）

- **Resources**：`oc://now`、`oc://episodes/{date}`、`oc://episode/{id}`、`oc://event/{id}`、`oc://entity/{id}`。
- **Tools**：
  - `search_context`
  - `get_timeline`
  - `related`（Promnesia 式，沿链接和实体扩展）
  - `what_was_i_doing(at)`
  - `get_facts(subject, as_of)`
  - `expand(id, level)`
- **约束**：每条返回都带溯源；支持 token 预算参数；敏感级别的数据默认不出本机。

### 评测设计（R-09 的输入）

- **数据**：自己采集 1–2 周的真实数据（脱敏），再用脚本生成合成剧本（"语音 → 浏览 → 复制 → 通知"），合成数据的真实链接天然已知。
- **任务类型**：
  1. 跨渠道召回
  2. 时间推理
  3. 隐式失效（STALE 式）
  4. 拒答
  5. 前瞻提醒
  6. 下游任务结果
- **协议**：在线流式回放，严格遵守时间因果，防止信息泄漏。
- **消融**：只用原始检索 → 加链接 → 加 Episode → 加事实 → 完整分层视图；另设 oracle 上限。
- **指标**：答案准确率、证据召回与精度、链接的精确率/召回率、Episode 边界 F1、token 消耗与延迟、隐私泄露率。

## 5. 开放研究问题

1. 跨模态链接的置信度怎么校准？能否用"剪切板↔前台窗口"这种接近真值的信号做弱监督，自举出"语音↔网页"的链接？
2. 多任务交错时，一个事件能否同时属于多个 Episode？层次化的 Episode 怎么建？
3. 在多大的 token 预算下，摘要的收益为正？
4. 能否只从行为信号推断出"某条事实已经过期"？
5. 被动采集的系统怎么暴露前瞻意图（待办、提醒）？
6. 推断层带来的二次敏感性问题；本地 LLM 与云 LLM 的分工；用户删除数据时，派生物怎样级联清除。
7. 如何拿到不泄露隐私的真实评测数据？
8. "记忆到动作"的鸿沟：Context 用什么形式呈现，Agent 最容易用上？
9. 多设备时钟漂移和 ASR 时间戳误差，对时间对齐有多大影响？
