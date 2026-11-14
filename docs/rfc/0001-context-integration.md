# RFC 0001：跨渠道 Context 整合方法（草案）

- **状态**：Draft，待评审
- **依据**：[channels.md](../research/channels.md)、[channel-audio.md](../research/channel-audio.md)、[integration-methods.md](../research/integration-methods.md)

## 1. 要解决的问题

各渠道的数据在形态、时间粒度和可信度上都不一样：
- 语音：约 60 秒一段，时间是段内相对秒；
- 浏览：一段带停留时长的阅读；
- 剪切板：一个瞬间动作；
- 窗口焦点：连续的区间。

Agent 需要的不是一堆流水账，而是**"我刚才在做什么、和什么有关、证据在哪"**。

本 RFC 定义：统一事件模型、分层整合架构、跨渠道关联方法，以及 Agent 怎样读取这些数据。

## 2. 设计原则

1. **原文是唯一事实来源。** 链接、Episode、摘要、事实都可以从原始事件重新计算。摘要只用来导航，回答时必须能回溯到原文。依据：LifeDialBench、Context Rot。
2. **先做确定性处理，再用模型。** 能靠规则、锚点、时间区间解决的，不调用 LLM；LLM 只按需、在后台使用。
3. **每条数据都带溯源。** 每个派生结果都能指回原始事件，以及它在源系统里的 locator。
4. **时间有两条轴。** 事件发生时间（valid）和系统记录时间（observed）分开存。事实只关闭有效区间，不删除。依据：Graphiti、STALE。
5. **本地优先、默认最小化。** 敏感级别的数据默认不出本机；被过滤掉的内容不落盘。
6. **内容不是指令。** 返回给 Agent 的一切内容都标注为不可信数据。沿用 record-for-agent 的约定。
7. **不重复造轮子。** 已有系统（record-for-agent、ActivityWatch）作为数据源接入，不重新实现它们的采集和 MCP。

## 3. 分层架构

```text
L0 原始事件层  Event Log（append-only）     ← 各渠道 connector 写入
L1 链接层      Links（带置信度与证据）       ← 规则 / 指纹 / 时间 / 语义
L2 情景层      Episodes（一段连贯的活动）     ← 边界检测 + 后台摘要
L3 语义层      Entities + Facts（双时间轴）   ← 可选，M2 之后再做
L4 视图层      MCP resources / tools          ← 分 L0/L1/L2 渐进加载
```

**M1 只实现 L0、L1、L2，以及最小的 L4。** L3 留到有评测数据证明需要时再做。

## 4. 统一事件模型（L0）

```text
event {
  id              ULID
  source          voice | browser | clipboard | ai_chat | window | ...
  kind            transcript_segment | page_read | copy | chat_turn | focus | ...
  t_start, t_end  整数 Unix 毫秒（瞬时事件 t_end = t_start）
  tz, tz_source   时区与来源（recorded | utc_fallback），不推断缺失信息
  t_observed      写入时间（系统时间轴）
  device_id       采集设备
  actor           self | speaker_k | app | unknown
  content         { text, title, url_norm, lang, content_hash, minhash? }
  context         { app_bundle, window_title, dwell_ms, scroll_depth, afk, geo? }
  anchors[]       从内容中抽取的键：url、domain、file_path、repo、entity …
  attention       0–1，由各渠道按自己的规则计算，并记录计算方法
  provenance      { connector, version, locator, source_id, source_hash, derived_from[] }
  privacy         { tier: local_only | redacted | shareable, pii_tags[], retention }
}
```

**各渠道的映射要点：**
- **语音**：`source_id = recordingID`，`source_hash = audioSHA256`，`locator = record-for-agent:get_transcript(id)`。转写 span 的墙钟时间 = `startedAt + start × 1000`。同一 `recordingGroup` 内的分段在 L2 拼接。`device_id` 缺失，暂时记为 `watch`。
- **浏览器**：一次有效阅读算一个事件。`t_start/t_end` 为首次与最后一次活跃的时间，`dwell_ms` 为有效停留时长；只有超过阈值才写入正文。
- **剪切板**：瞬时事件。context 记录来源 App 和窗口；粘贴目标作为后续补充写入 `context`。
- **AI 对话**：每一轮对话算一个事件，`locator` 指向会话文件和轮次。
- **窗口焦点**：区间事件，heartbeat 合并后写入。

**幂等**：用 `(source, source_id, source_hash)` 唯一确定一个事件。同一个键对应不同内容时报 `conflict`，沿用 record-for-agent 的约定。

## 5. 跨渠道关联（L1）

按成本从低到高依次计算，结果统一存成 `link{src, dst, type, confidence, evidence, method@version}`：

| 级别 | 方法 | 产生的链接类型 | 典型场景 |
| :--- | :--- | :--- | :--- |
| 1 | URL / 文件路径 / 仓库等锚点精确匹配 | `same_anchor` | 剪切板里的 URL ↔ 浏览器页面 |
| 2 | 内容指纹（子串 / MinHash 包含） | `copy_of` | 剪切板文本 ↔ 网页正文 / AI 回答 |
| 3 | 时间区间求交 | `during` | 剪切板事件 ↔ 当时的前台窗口 / 标签页（几乎是真值） |
| 4 | 时间邻近（≤15 分钟、中间无 AFK、按时间衰减）+ 语义相似 + 实体重叠 | `related` | 语音讨论 ↔ 10 分钟后读的网页 |
| 5 | 融合打分 | 超过阈值才建立链接 | 先用规则加权，有标注后再学习权重 |

## 6. Episode（L2）

- **边界信号**（组合判断）：
  - 空闲超过阈值；
  - 前台应用 / 项目切换；
  - 相邻窗口的语义漂移；
  - 语音的 `recordingGroup` 开始或结束。
- **内容**：成员事件 ID 列表、时间范围、主要渠道、一句话摘要和约 2k token 的概述（后台生成），以及边界原因。
- **允许重叠**：一个事件可以同时属于多个 Episode，例如边开会边查资料。这一点是否保留，需要评测验证。

## 7. Agent 读取方式（L4 · MCP）

最小工具集（M1）：

| 工具 | 作用 |
| :--- | :--- |
| `what_was_i_doing(at?, minutes?)` | 返回当前或指定时刻附近的 Episode 概述，以及关键证据 |
| `search_context(query, time_range?, sources?, k?)` | 全文检索 + 时间过滤，返回 Episode 级结果和证据片段 |
| `related(id \| url \| text)` | 沿链接扩展，即"我在哪里还见过它"（Promnesia 式） |
| `expand(id, level)` | 按需下钻：一句话摘要 → 概述 → 原文 |

**约束：**
- 每条返回都带 `provenance` 和时间；
- 支持 token 预算参数；
- `local_only` 级别的数据默认不返回；
- 音频的专有工具不重复暴露，通过 locator 指向 record-for-agent。

## 8. 场景走查

**场景 A：线下讨论 → 查资料 → 写代码**
1. 10:00–10:12，Watch 录下一段讨论，提到"SenseVoice 量化"。L0 写入 12 个 `transcript_segment`。
2. 10:18，浏览器有效阅读 sherpa-onnx 文档 4 分钟，期间复制了一段命令。L0 写入 `page_read` 和 `copy`。
3. L1：`copy` 与 `page_read` 通过内容指纹匹配，生成 `copy_of`；`copy` 与当时的前台标签页通过时间区间求交，生成 `during`；页面与语音之间时间相隔 6 分钟、中间无 AFK，且都出现了 "SenseVoice"，生成 `related`。
4. L2：三者落进同一个 Episode，"SenseVoice 部署调研"。
5. 用户在 Cursor 里说"按刚才讨论的方案写部署脚本"。Agent 调用 `what_was_i_doing(minutes=60)`，拿到 Episode 概述、复制的命令原文，以及讨论片段的 locator。

**场景 B：隐式状态变化**
1. 周一的语音里说"用方案 A"；周三浏览和复制的内容都转向了方案 B，AI 对话里也在问 B 的报错。
2. M1 的处理：`search_context("方案")` 按时间衰减排序，返回结果同时带上两个 Episode 的时间，交给 Agent 判断。
3. M2 的处理：L3 记录事实"项目使用 A"，将其有效区间关闭在周三，标注 superseded。

**场景 C：只有剪切板，没有其他上下文**
1. 用户复制了一段报错，当时前台是终端，窗口标题里有仓库名。
2. L1：锚点 `repo` 关联到同一仓库的 AI 对话和 Git 活动（Phase 2 接入）。
3. 如果找不到任何关联，Episode 标记为"孤立"，供后续缺口检测使用（M2）。

## 9. 不在本 RFC 范围内

- L3 事实层的具体抽取方法；
- 缺口检测与主动补全的交互设计；
- 移动端渠道；
- 存储引擎选型细节（倾向 SQLite + FTS5，向量索引按需引入）。

## 10. 待评审决策

1. **Episode 允许重叠吗？**（建议：允许，由评测决定是否保留）
2. **M1 包含 L3 事实层吗？**（建议：不包含）
3. **窗口焦点先接入 ActivityWatch，还是自研？**（建议：先接入）
4. **AI 对话历史纳入 Phase 1 吗？**（建议：纳入，成本低、价值极高）
5. **隐私分级的默认值**：新渠道默认 `local_only`，用户显式放开后才变为 `shareable`。
