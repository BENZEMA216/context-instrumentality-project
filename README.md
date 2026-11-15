<p align="center">
  <img src="assets/eva-context-banner.png" alt="CONTEXT 补全计划 · The Context Instrumentality Project" width="100%" />
</p>

# Context 补全计划 · The Context Instrumentality Project

> **个人多源上下文的统一归档、研究基座与 Agent 记忆补全实验计划**  
> 本仓库当前作为**研究型开源知识库（Research-First Archive）**维护：首页即完整的学习索引与四维精读手册，系统归档 **24 项代表性开源项目**、**16 篇学术论文与评测基准** 及 **6 篇工程报告与系统规范**，沉淀出可直接指导 `L0 → L4` 个人上下文整合层落地的架构决策。

- **当前阶段**：已完成渠道优先级盘点、核心整合方法调研、先驱项目源码/论文/博客四维精读，以及音频（`record-for-agent`）与剪切板（`ClipContext`）双通道采集原型合并；下一步进入统一 SQLite 底座 + Event 聚合 + MCP 检出层联调。
- **核心结论先行**：
  1. **Instrumentality Over Raw Archive（工具效用优于原始堆积）**：Chroma *Context Rot* 与 Anthropic *Context Engineering* 共同证明，盲目把海量原始记录灌进长窗口只会稀释注意力；个人上下文系统的终点是**面向下游 Agent 动作与决策的按需高信噪比注入（Just-in-Time Retrieval）**，而非“只写不读的数据坟墓”。
  2. **Layered Fidelity（`L0 → L4` 分层保真 + 双时序演进）**：严格遵守 *Episodic Memory* 与 *Zep/Graphiti* 的分层原则——`L0/L1` 原始事件保留可回跳原文件的 `locator` 且只追加不覆盖；`L2` 情景（Episode）借鉴 *EST* 与 *EM-LLM* 按预测误差、AFK 间隙与切换边界聚合；`L3` 个人知识与状态事实显式维护双时序区间（`valid_from` / `valid_to`），防止过时记忆（*STALE*）污染当前判断。
  3. **High-SNR Local-First Channels（高信噪比本地优先通道切入）**：从“本地录音 + 离线 ASR”（`record-for-agent` + `FunASR/SenseVoice/sherpa-onnx`）与“显式高意图剪切板”（`ClipContext` + `nspasteboard.org` 隐私红线）切入，辅以三层信号过滤后的浏览器正文（Defuddle/Readability）与窗口/Shell 状态，克制初期重型基础设施与低信噪比全屏截屏 OCR 依赖。

---

## 目录导航

- [一、 本仓库专题研究归档](#一-本仓库专题研究归档)
- [二、 开源项目分类索引与四维精读（24 项）](#二-开源项目分类索引与四维精读24-项)
  - [2.1 个人数据统一与时间线归档（4 项）](#21-个人数据统一与时间线归档4-项)
  - [2.2 端侧感官与桌面 / 浏览器采集（10 项）](#22-端侧感官与桌面--浏览器采集10-项)
  - [2.3 Agent 记忆与 Context 基础设施（5 项）](#23-agent-记忆与-context-基础设施5-项)
  - [2.4 主动式个人上下文与“第二大脑”应用（5 项）](#24-主动式个人上下文与第二大脑应用5-项)
- [三、 学术论文与评测基准索引与四维精读（16 篇）](#三-学术论文与评测基准索引与四维精读16-篇)
  - [3.1 连续生活流与 Agent 长期记忆评测（7 篇）](#31-连续生活流与-agent-长期记忆评测7-篇)
  - [3.2 事件分割、情景记忆与系统架构（6 篇）](#32-事件分割情景记忆与系统架构6-篇)
  - [3.3 经典奠基文献（3 篇）](#33-经典奠基文献3-篇)
- [四、 技术博客、工程报告与系统规范（6 篇）](#四-技术博客工程报告与系统规范6-篇)
- [五、 仓库结构与已接入采集端](#五-仓库结构与已接入采集端)

---

## 一、 本仓库专题研究归档

| 归档文档 | 内容覆盖与定位 | 适用阅读场景 |
| :--- | :--- | :--- |
| [docs/research/projects-digest.md](docs/research/projects-digest.md) | **24 项开源项目四维精读**（问题 / 方法 / 前后对照 / 对本计划的提示）独立归档副本 | 离线全文阅读与项目横评对比 |
| [docs/research/papers-blogs-digest.md](docs/research/papers-blogs-digest.md) | **16 篇论文与评测 + 6 篇工程博客/规范四维精读** 独立归档副本 | 学术依据查证与评测标准对照 |
| [docs/research/channels.md](docs/research/channels.md) | 12 条个人 Context 采集渠道可行性、信噪比、合规与隐私红线分级排序 | 决定下一批先接哪条数据通道 |
| [docs/research/integration-methods.md](docs/research/integration-methods.md) | 11 个先驱系统字段盘点、6 类融合策略横评、`L0 → L4` 架构与 MCP 工具草案 | 架构选型与 L1–L4 数据流设计 |
| [docs/research/channel-audio.md](docs/research/channel-audio.md) | `record-for-agent` 录音采集端代码盘点、SQLite 表设计思路与待补缺口 | 了解音频通道现状与本地 ASR 选型 |
| [docs/research/channel-clipboard.md](docs/research/channel-clipboard.md) | `ClipContext` 剪贴板采集器：`clipboard.json`、`revision`/SHA-256 指纹与 MCP | 了解剪贴板通道设计与安全隔离 |
| [docs/research/landscape.md](docs/research/landscape.md) | Dark Context 问题定义与早期生态版图梳理初稿 | 回顾立项初始调研脉络 |
| [docs/rfc/0001-context-integration.md](docs/rfc/0001-context-integration.md) | **RFC-0001**：个人多源 Context 整合统一协议、分层存储与接入规范草案 | 制定核心代码模块实现标准 |
| [schema/context-event.schema.json](schema/context-event.schema.json) | 统一 L1 `ContextEvent` JSON Schema 定义 | 校验各采集端写入事件格式 |

---

## 二、 开源项目分类索引与四维精读（24 项）

> 完整独立归档版本见：[docs/research/projects-digest.md](docs/research/projects-digest.md)。以下在每个分类总表下方直接展开每项的**四维精读**。

### 2.1 个人数据统一与时间线归档（4 项）

| # | 项目 | 定位与核心特点 | 仓库链接 |
| :---: | :--- | :--- | :--- |
| 1 | **Promnesia** | 个人历史反向叠加层（URL 规范化 + 原文 Locator 回跳） | https://github.com/karlicoss/promnesia |
| 2 | **HPI** | 个人数据导出格式适配层（Python 统一接口 + 解耦原始快照） | https://github.com/karlicoss/HPI |
| 3 | **Timelinize** | Go + 本地存储的多源数字足迹个人时间线归档桌面应用 | https://github.com/timelinize/timelinize |
| 4 | **Dogsheep** | `*-to-sqlite` 微工具集 + Datasette 个人 SQLite 数据仓库 | https://dogsheep.github.io/ |

#### 2.1.1 karlicoss/promnesia
- **仓库链接**：https://github.com/karlicoss/promnesia
- **1. 核心解决的问题**：人在浏览网页、研究技术或重访历史链接时，常忘记“以前在哪儿见过它、当时和谁在聊什么或记过什么笔记”，历史上下文散落在浏览器历史、IM、Markdown 与书签数十个孤岛中。
- **2. 使用的方法**：采用源索引器（Sources）+ URL 规范化（Canonical URL Normalization）+ 本地索引存储（围绕 `url`、`dt`、`locator`、`context`、`duration` 等核心语义建表）+ 浏览器侧边栏扩展，在重访页面时实时叠加上下文来源与回跳链接。
- **3. 解决前后的对照**：**Before** — 想查一条链接出处得在 Chrome、Telegram、Obsidian 间分别手工检索且常漏掉对话语境；**After** — 打开网页即可在侧边栏一目了然看到过往提及时间、所在对话片段及直达源文件的 Locator。
- **4. 对「Context 补全计划」的提示与指示**：`L0/L1` 事件模型必须硬性保留可回跳原文件的 `locator`（音频起止时间戳、网页规范化 URL、文件定位）；URL 规范化是打通剪切板复制链接与浏览历史合流的必备步骤。

#### 2.1.2 karlicoss/HPI (Human Programming Interface)
- **仓库链接**：https://github.com/karlicoss/HPI
- **1. 核心解决的问题**：各平台个人数据导出包格式迥异（JSON、CSV、SQLite、GDPR 压缩包），每次写脚本或接 AI 工具都要重写脆弱的解析逻辑。
- **2. 使用的方法**：保持各渠道原始导出文件原地不可变落盘，向上通过模块化 Python `my.*` 包统一抽象成带类型标注的 Iterator / 数据模型，并支持轻量缓存与叠加转换。
- **3. 解决前后的对照**：**Before** — 每接一个新消费端就要重复适配十几种平台导出细节，源格式小改即全盘报错；**After** — 消费逻辑只面向统一 Python 接口编程，原始导出包完整保存，支持未来随时换新算法无损重算。
- **4. 对「Context 补全计划」的提示与指示**：采用“`L0` 各自原样归档 + `L1` 映射统一 `ContextEvent` Schema”的解耦设计，日后升级离线 ASR、分割或实体抽取模型时可直接从 `L0` 重跑生成新版记忆。

#### 2.1.3 timelinize/timelinize
- **仓库链接**：https://github.com/timelinize/timelinize
- **1. 核心解决的问题**：照片、位置轨迹、消息记录与本地文件各自躺在不同应用里，缺少按统一时间与人物/地点维度交汇回放的本地个人时间轴软件。
- **2. 使用的方法**：基于 Go 与本地 SQLite/文件系统构建多源导入管线（据公开项目文档），把跨平台导出的记录归并进统一本地时间线并关联实体、媒体附件与位置属性，配合图形时间线界面浏览。
- **3. 解决前后的对照**：**Before** — 还原某天某地做过什么事需要在相册、聊天记录、地图轨迹和文档之间手动核对时间戳；**After** — 所有足迹收敛在单一可控的本地时间轴视图，无需依赖云端产品续存。
- **4. 对「Context 补全计划」的提示与指示**：UTC 时间轴是全渠道天然的公共主键；同时需为系统留好“实时采集守护进程 + 历史离线批导入器”双入口，避免只管增量不管存量。

#### 2.1.4 Dogsheep
- **项目主页**：https://dogsheep.github.io/
- **1. 核心解决的问题**：个人从社交平台、GitHub、健康与书签导出的 JSON/API 数据难以像标准数据库表一样直接进行跨源 SQL 关联分析和全文探索。
- **2. 使用的方法**：倡导 **“SQLite 个人数据仓库”** 模式，为每个服务开发独立轻巧的 `*-to-sqlite` CLI（如 `github-to-sqlite`、`google-takeout-to-sqlite`），把分散数据写入标准化 SQLite 文件，并配合 `Datasette` 即刻提供 Web 查询、FTS5 全文索引与 JSON API。
- **3. 解决前后的对照**：**Before** — 导出包躺在磁盘里成“只写不读的数据坟墓”；**After** — 单文件 SQLite 即可运行跨表 SQL Join 与秒级全文搜索，无运维门槛且易于备份迁移。
- **4. 对「Context 补全计划」的提示与指示**：验证了本项目 MVP 阶段选择 **SQLite + FTS5** 作为本地统一底座的合理性——保持每个端侧采集器轻量独立（`record-for-agent`、`ClipContext` 等），统一合流进单机数据库。

---

### 2.2 端侧感官与桌面 / 浏览器采集（10 项）

| # | 项目 | 采集通道与定位 | 仓库链接 |
| :---: | :--- | :--- | :--- |
| 5 | **ActivityWatch** | 桌面窗口焦点、AFK 空闲状态与浏览活跃时间监控（Heartbeat 合并） | https://github.com/ActivityWatch/activitywatch |
| 6 | **Maccy** (+ `ClipContext`) | macOS 高意图剪贴板历史监听、隐私过滤与本地化扩展基线 | https://github.com/p0deje/Maccy |
| 7 | **Defuddle & Obsidian Clipper** | 现代网页正文抽取去噪 + Markdown 模板化网页剪藏 | https://github.com/kepano/defuddle · https://github.com/obsidianmd/obsidian-clipper |
| 8 | **Mozilla Readability** | Firefox 阅读视图底层 DOM 启发式正文提取标准基线 | https://github.com/mozilla/readability |
| 9 | **WorldBrain Memex** | 浏览器历史阅读正文自动全文索引、片段高亮与批注记忆 | https://github.com/WorldBrain/Memex |
| 10 | **Omi** | 开源可穿戴语音采集硬件/App + 转写 + 记忆/待办提取流水线 | https://github.com/BasedHardware/omi |
| 11 | **screenpipe & OpenRecall** | 低频桌面截屏 OCR / 音频全时记录栈（视觉盲区对照组与兜底思路） | https://github.com/screenpipe/screenpipe · https://github.com/openrecall/openrecall |
| 12 | **Atuin** | Shell 命令结构化历史入库（指令/目录/耗时/退出码）与加密同步 | https://github.com/atuinsh/atuin |
| 13 | **Dawarich** | 自托管个人长期 GPS 位置轨迹与造访地点聚合平台 | https://github.com/Freika/dawarich |
| 14 | **FunASR / SenseVoice / sherpa-onnx** | 离线语音识别全栈：VAD、中文高精 ASR、情感/事件标注与端侧 ONNX 推理 | https://github.com/modelscope/FunASR · https://github.com/FunAudioLLM/SenseVoice · https://github.com/k2-fsa/sherpa-onnx |

#### 2.2.1 ActivityWatch (ActivityWatch/activitywatch)
- **仓库链接**：https://github.com/ActivityWatch/activitywatch
- **1. 核心解决的问题**：人机交互过程中缺乏一条客观记录“每分钟焦点究竟在哪个应用、哪个窗口、以及键鼠是否活跃”的本地底层时间线，难以划定工作区间与区分挂机时间。
- **2. 使用的方法**：采用 `aw-server`（SQLite + Bucket/Event API）配合 `aw-watcher-window`、`aw-watcher-afk`、`aw-watcher-web` 等解耦采集插件，核心利用 **Heartbeat 合并机制** 把连续相同窗口/活跃状态的轮询脉冲压缩为单条带起止与 `duration` 的时间区间。
- **3. 解决前后的对照**：**Before** — 按秒记流水账会迅速胀爆数据库，且电脑锁屏挂机也会被错算成阅读/编码时长；**After** — 紧凑记录真实聚焦活动区间与 AFK 离席分界。
- **4. 对「Context 补全计划」的提示与指示**：窗口与网页停留采集必须使用 **Heartbeat 区间合并** 抑制写放大；AFK 空闲信号本身就是 `L2 Episode` 会话切割的天然低成本边界依据。

#### 2.2.2 Maccy (p0deje/Maccy) + 本仓 ClipContext
- **仓库链接**：https://github.com/p0deje/Maccy
- **1. 核心解决的问题**：系统剪贴板默认只保留最后一条，开发或办公中显式复制的代码片段、报错信息、重要网址一旦再次复制即永久丢失，且普通剪贴工具不向 AI Agent 暴露可编程上下文。
- **2. 使用的方法**：Maccy 通过监听 `NSPasteboard.changeCount` 持久化剪切历史并过滤密码管理器等敏感应用与 `nspasteboard.org` 特殊标记；本仓 `ClipContext` 继承该思路并在本地 `clipboard.json` 中记录 `revision`、SHA-256 指纹与多模态载荷，直接暴露 `recent / search / get` MCP 接口。
- **3. 解决前后的对照**：**Before** — 刚才跨软件搬运过哪段报错或参数日志过眼即忘，Agent 只能让用户重新复制粘贴；**After** — 每次显式 `Cmd+C` 化为经过用户人工筛选的高信噪比意图流，Agent 可按时间或关键词直接调取。
- **4. 对「Context 补全计划」的提示与指示**：剪切板是仅次于录音的高信噪比文字通道；同时必须严格遵守 `nspasteboard.org` 瞬态/机密协议与 macOS 15.4+ 剪贴板权限规范，敏感凭证零落盘。

#### 2.2.3 Defuddle (kepano/defuddle) & Obsidian Web Clipper (obsidianmd/obsidian-clipper)
- **仓库链接**：https://github.com/kepano/defuddle · https://github.com/obsidianmd/obsidian-clipper
- **1. 核心解决的问题**：直接保存完整网页 HTML 会引入海量侧边栏、广告、推荐流与样式脚本，既浪费大模型 Token 又污染检索召回精度。
- **2. 使用的方法**：`defuddle` 针对现代复杂页面结构先剥离非正文区块并抽出作者、发布时间等 Metadata，最终输出干净标准化 Markdown；`obsidian-clipper` 将其嵌入浏览器插件并支持字段模板化归档本地。
- **3. 解决前后的对照**：**Before** — 存下来的网页混杂无关菜单导航与脚本噪声，向量检索经常命中页脚文本；**After** — 沉淀体积紧凑、结构清晰的纯净 Markdown 正文与元数据，同时兼顾人读与机读。
- **4. 对「Context 补全计划」的提示与指示**：浏览器通道不可只记易失效的 URL——确认页面“有效停留”后即用 Defuddle 级抽提器转为 Markdown 并做内容指纹去重，才能沉淀长效可用的 `L1` 阅读快照。

#### 2.2.4 Mozilla Readability (mozilla/readability)
- **仓库链接**：https://github.com/mozilla/readability
- **1. 核心解决的问题**：互联网网站 HTML 标签千奇百怪，很难靠手写站内 CSS 选择器稳定抽取所有文章、博客和新闻页的正文主体。
- **2. 使用的方法**：基于 Firefox 阅读视图沉淀的纯 JS DOM 启发式算法，统计段落文本密度、标点密度、链接密度（排除目录导航与侧栏）与正向/负向类名权重，经父节点累加评分定位最优正文子树。
- **3. 解决前后的对照**：**Before** — 每换一个资讯网站就要写一套脆性的 XPath 抽取规则；**After** — 一套通用启发式引擎覆盖绝大多数常规文章页，确立了网页阅读正文抽取的基础工业基线。
- **4. 对「Context 补全计划」的提示与指示**：浏览器抓取管线可采用 **“Defuddle 优先 + Readability 回退/交叉校验”** 策略，确保面对不同年代和结构的长文网页都能稳健提取主内容。

#### 2.2.5 WorldBrain Memex (WorldBrain/Memex)
- **仓库链接**：https://github.com/WorldBrain/Memex
- **1. 核心解决的问题**：浏览器常规历史只索引网页标题与 URL、书签依赖手动打标，导致“我曾经细读过一篇讲某机制的文章却怎么也搜不出来”。
- **2. 使用的方法**：浏览器扩展在页面浏览停留后自动本地提取正文建全文索引，同时支持用户在页面划词高亮、写批注并按 Space 组织专题，实现零手工收藏下的全网已读正文反查。
- **3. 解决前后的对照**：**Before** — 只记得文章内部某个概念词却记不起域名，重搜全网往往无果；**After** — 自己看过的每一页正文都变成可按关键词、时间与个人批注瞬间招回的个人搜索引擎。
- **4. 对「Context 补全计划」的提示与指示**：确认了**“自动静默索引 + 人工主动高亮/批注加权”**混合设计的威力——日常页面后台低打扰记摘要，用户主动划词或复制的片段直接标高权重进核心记忆。

#### 2.2.6 Omi (BasedHardware/omi)
- **仓库链接**：https://github.com/BasedHardware/omi
- **1. 核心解决的问题**：大量重要决策、线下探讨与即时灵感发生在离开桌面键盘的面对面/日常走动中，传统长录音文件难以消化利用，导致离线现实世界与数字助手完全断联。
- **2. 使用的方法**：开源可穿戴拾音硬件 + Companion App + 开放后端生态（据公开项目文档）：利用 VAD 检测语音片段并实时/准实时转写，下游由 LLM 从对话流自动提炼结构化记忆（Memories/Facts）、行动待办与摘要，再通过 App/Webhook 分发。
- **3. 解决前后的对照**：**Before** — 几小时的口头讨论要么没人录音随风散去，要么留下没人有耐心从头听完的巨大音频文件；**After** — 离线语音交谈自动转为可读可检索的结构化事件流与待办清单。
- **4. 对「Context 补全计划」的提示与指示**：正面验证了本仓重点深耕音频通道（`record-for-agent`）的价值；同时启示我们将“低功耗专注采音 + VAD”和“后台转写/摘要/记忆抽取流水线”彻底解耦。

#### 2.2.7 screenpipe (screenpipe/screenpipe) & OpenRecall (openrecall/openrecall)
- **仓库链接**：https://github.com/screenpipe/screenpipe · https://github.com/openrecall/openrecall
- **1. 核心解决的问题**：封闭桌面软件（无 API 的私聊窗口、视频会议共享屏幕、扫描版 PDF）里的内容不会进入剪贴板或浏览器扩展，存在传统 API 集成难以触及的视觉采集盲区。
- **2. 使用的方法**：通过定时低频屏幕截图 + 本地 OCR（`screenpipe` 基于 Rust 还整合了系统音频转写并暴露本地 SQLite/检索接口与插件生态；`OpenRecall` 主打轻量 Python 本地截屏 OCR 与时间轴检索）。
- **3. 解决前后的对照**：**Before** — 屏幕上闪现过的图表文字或未复制的 IM 对话一旦关掉便彻底失忆；**After** — 屏幕曾渲染过的所有可读视觉文字都成为可回溯检索的历史库。
- **4. 对「Context 补全计划」的提示与指示**：全时截屏 + OCR 噪声极高、耗电/占盘明显且极易同屏误拍机密与私聊隐私；在本计划中**仅定位为“对照组研究”与按需显式触发的兜底手段**，坚持以高信噪比结构化信道（音频/剪贴板/浏览器/Shell）为主力。

#### 2.2.8 Atuin (atuinsh/atuin)
- **仓库链接**：https://github.com/atuinsh/atuin
- **1. 核心解决的问题**：默认 Shell 文本历史（`.zsh_history`）易丢失、缺执行目录、缺退出码与耗时记录，无法按项目语境精准追溯“之前我在哪个目录把什么跑通了”。
- **2. 使用的方法**：用 Rust 重写历史后端，将每次命令作为完整结构化行写入本地 SQLite（含命令、`cwd`、时间、`duration` 耗时、`exit` 退出码、`session` 会话与主机名），并支持端到端加密同步与交互搜索。
- **3. 解决前后的对照**：**Before** — 只记得大概敲过一个编译或清理指令，但不知道在哪个项目目录跑过、到底成功还是报错；**After** — 5 个核心极简字段构成了精确的开发过程工作流轨迹，按目录和退出状态一查便知。
- **4. 对「Context 补全计划」的提示与指示**：极佳的**“轻字段高推导力”**示范——记录极轻的命令元信息（尤其 `cwd` 和 `exit_code`），就能让编程 Agent 自动识别排错起始与闭环节点（连续失败退出聚合 = 一次排错 Episode）。

#### 2.2.9 Dawarich (Freika/dawarich)
- **仓库链接**：https://github.com/Freika/dawarich
- **1. 核心解决的问题**：云端位置时间线服务逐步退坡或受限，个人需要自主掌握数十年跨度的地理移动轨迹与常去地点语义记录。
- **2. 使用的方法**：可 Docker 自托管的位置历史平台，兼容 Google Takeout、OwnTracks、Overland、Home Assistant 等多种轨迹导入与持续上报源，在自有实例中聚类常访地点（Places/Visits）并暴露地图与 API。
- **3. 解决前后的对照**：**Before** — 物理行踪与数字工作笔记割裂在厂商孤岛中；**After** — 个人物理时空轨迹完全本地/私有可控，能与其他渠道日志按时间锚点关联。
- **4. 对「Context 补全计划」的提示与指示**：虽然地理轨迹不是第一阶段必接传感器，但必须在 `ContextEvent` Schema 中预留 `location / place` 可选扩展维度——**“地点 + 时间”**往往是触发人类特定记忆与会议回忆的关键线索。

#### 2.2.10 FunASR / SenseVoice / sherpa-onnx（本地语音识别技术栈）
- **仓库链接**：https://github.com/modelscope/FunASR · https://github.com/FunAudioLLM/SenseVoice · https://github.com/k2-fsa/sherpa-onnx
- **1. 核心解决的问题**：全天候随身/桌面录音若依赖云端商业语音 API，不仅账单高昂且把全天私密对话发给第三方存在不可接受的隐私风险；早期离线方案则常受中英混读错词、缺标点与推理框架复杂困扰。
- **2. 使用的方法**：`FunASR` 覆盖工业级 VAD + 语音识别 + 标点恢复（PUNC）+ 说话人分离完整管线；`SenseVoice` 在多语种与中英混读高精识别上同步输出语音情感与非人声事件标签；`sherpa-onnx` 基于 ONNX Runtime 提供无臃肿依赖、跨 macOS/移动端的高速离线推理封装。
- **3. 解决前后的对照**：**Before** — 离线语音要么识别成一团无标点乱码、要么被迫传云端 API；**After** — 在笔记本本地离线 CPU/端侧硬件即可跑出带精准标点、中英混合流畅且附带情感/说话人提示的高质量文本流。
- **4. 对「Context 补全计划」的提示与指示**：这是打通本仓 **`record-for-agent` 本地隐私闭环** 的核心底座——务必采用“本地 VAD 先剔除静音区间 + 离线 ASR（`sherpa-onnx` / `SenseVoice` / `FunASR`）转写 + 时间戳挂回音频原文件 Locator”流水线。

---

### 2.3 Agent 记忆与 Context 基础设施（5 项）

| # | 项目 | 核心记忆范式 | 仓库链接 |
| :---: | :--- | :--- | :--- |
| 15 | **OpenViking** | 面向 Agent 的虚拟文件系统上下文库（`viking://` + `L0/L1/L2` 渐进按需加载） | https://github.com/volcengine/OpenViking |
| 16 | **Graphiti** | 双时序动态知识图谱引擎（Zep 底层，显式边有效期 `valid_at/invalid_at` + 混合召回） | https://github.com/getzep/graphiti |
| 17 | **Mem0** (+ `chrome-extension`) | `ADD/UPDATE/DELETE/NOOP` 两阶段增量记忆维护 + 跨网页 AI 注入扩展 | https://github.com/mem0ai/mem0 |
| 18 | **Letta** | 类 OS 分页内存模型（Core / Recall / Archival + Agent 工具自管理） | https://github.com/letta-ai/letta |
| 19 | **cognee** | 异步 ECL（Extract-Cognify-Load）管线同步驱动图库 + 向量库多模召回 | https://github.com/topoteretes/cognee |

#### 2.3.1 OpenViking (volcengine/OpenViking)
- **仓库链接**：https://github.com/volcengine/OpenViking
- **1. 核心解决的问题**：平面向量库（Flat RAG）把所有文档和记忆打散成平等 Chunk，缺少全局层次结构，检索要么丢失背景上下文、要么每次塞大段全文造成巨大 Token 浪费。
- **2. 使用的方法**：开创面向 Agent 的“上下文数据库 / 虚拟文件系统（`viking://`）”，把记忆、资源与技能统一组织成层级目录树，并为节点建立 **L0（极简概览）→ L1（结构摘要）→ L2（完整详情）三级按需渐进加载机制**，兼顾目录收敛定位与可追踪检索路径。
- **3. 解决前后的对照**：**Before** — RAG 像盲人摸象般一次性堆砌全局相似度 Top-K 文本块；**After** — Agent 如浏览器/终端翻阅有条理目录一样先看摘要目录决定方向，再逐层钻取所需精确原文段落。
- **4. 对「Context 补全计划」的提示与指示**：直接强化本项目的分层检索策略——我们的 MCP 服务端必须提供 **“摘要列表先行 → 按 Episode ID 或时间窗口懒加载全文”** 的多级接口，绝不粗暴回传万字录音全文。

#### 2.3.2 Graphiti (getzep/graphiti)
- **仓库链接**：https://github.com/getzep/graphiti
- **1. 核心解决的问题**：普通图谱和静态向量库一旦遭遇事实随时间改变（如计划改期、技术栈替换、职责变更），新旧事实就会在检索时互相打架且难以低成本增量刷新。
- **2. 使用的方法**：围绕 Episodic / Entity / Community 节点构建**双时序（Bi-temporal）动态知识图谱**，每条事实边维护事件发生有效起止时间区间与系统记录时间；新事件写入时检测与既有边冲突并逻辑标废旧边（保留历史可查，不物理删除），检索融合向量、BM25 与图游走。
- **3. 解决前后的对照**：**Before** — 存进“上周准备用方案 A”和“今天拍板改方案 B”，语义搜经常把方案 A 一并吐出来误导模型；**After** — 兼顾“现在真实生效的是什么”和“历史上什么时候变成这样的”，增量入库不需全图重抽。
- **4. 对「Context 补全计划」的提示与指示**：个人状态图谱（`L3`）必须采用**双时序/有效区间建模**与**BM25+向量+图混合召回**，专治人名、文件ID 精确匹配及状态更新场景。

#### 2.3.3 Mem0 (mem0ai/mem0 & mem0-chrome-extension)
- **仓库链接**：https://github.com/mem0ai/mem0
- **1. 核心解决的问题**：用户在不同会话与不同 AI 产品之间不断重复背景解释，而若把每次对话毫无过滤地追加存储，记忆池会迅速充斥重复、冲突与过时琐碎条目。
- **2. 使用的方法**：设计了两阶段记忆整理管线——抽取新候选事实后检索邻近历史条目交由 LLM 控制器执行 **`ADD` / `UPDATE` / `DELETE` / `NOOP`** 四类增量合并操作（并在 `Mem0g` 版加入图三元组），同时借助 `mem0-chrome-extension` 直接跨 ChatGPT / Claude / Perplexity 注入个人共享记忆层。
- **3. 解决前后的对照**：**Before** — 换一个网页 AI 或新建窗口助手就彻底失忆，长聊天记录全量代入成本太高；**After** — 在极精简可控 Token 预算内维持跨平台、跨会话自动去重演化的个人事实卡。
- **4. 对「Context 补全计划」的提示与指示**：`mem0-chrome-extension` 验证了**“把独立于单一 AI 厂商的个人记忆外挂回所有日常 AI 入口”**极高实用价值；但向 `L3` 引入 `UPDATE/DELETE` 合并逻辑时，必须强制保留指向 `L0/L1` 源事件 ID 的指针，绝不可销毁原始真相。

#### 2.3.4 Letta (letta-ai/letta)
- **仓库链接**：https://github.com/letta-ai/letta
- **1. 核心解决的问题**：常规 LLM 应用只是外部脚本单向塞给模型几个 RAG 片段的无状态推理，上下文超限就一刀截断，模型无法主动自主探索长程历史或修正错误认知。
- **2. 使用的方法**：将 MemGPT 虚拟内存思想工程化为持久化有状态 Agent 运行时：**常驻上下文窗口的 Core Memory（可读写核心记忆区块）+ 外部无限容量的 Recall Memory 与 Archival Memory**，直接开放工具调用权让模型自行检索、分页翻找、插入和局部改写记忆。
- **3. 解决前后的对照**：**Before** — 检索一锤子定音，一次 Top-K 没捞到关键前后文 Agent 就只能盲猜或失忆；**After** — Agent 具备了自主多次翻查归档、跨时间轴延续长任务的自我内存管理能力。
- **4. 对「Context 补全计划」的提示与指示**：把本计划设计的上下文引擎定位于**“面向任意 Agent 运行时（Claude Code / Cursor / Letta 等）的 Recall & Archival MCP 工具集”**，通过可组合工具让调用方按需探索邻居时间窗与前因后果，而不强锁死单一对话壳子。

#### 2.3.5 cognee (topoteretes/cognee)
- **仓库链接**：https://github.com/topoteretes/cognee
- **1. 核心解决的问题**：从混杂文本构建同时利用“语义向量相似度 + 图结构关系推理”的双模记忆底座往往需要写大量繁琐脆弱的胶水脚本，底层存储更换也很痛苦。
- **2. 使用的方法**：用可插拔异步 **ECL（Extract → Cognify → Load）数据管线** 和强类型 `DataPoint` 原语统一编排，支持数十种数据源抽取与多后端图/向量库协同落盘，并提供丰富的混合图-向量查询策略（`SearchType`）。
- **3. 解决前后的对照**：**Before** — 向量检索与图谱构建各维护一套孤立管线，数据状态易失步；**After** — 一条标准化异步流同时喂饱结构化关系网与语义检索池。
- **4. 对「Context 补全计划」的提示与指示**：启示本仓在架构上**彻底隔离实时采集（L0/L1 快速轻落盘）与异步认知加工（L2→L3 后台定时抽取关系/摘要）**，避免慢速 LLM 推理反过来拖死前台高频感官记录。

---

### 2.4 主动式个人上下文与“第二大脑”应用（5 项）

| # | 项目 | 应用形态与核心关注 | 仓库链接 |
| :---: | :--- | :--- | :--- |
| 20 | **MineContext** | 主动式个人上下文伙伴（多端活动抓取 + 日报/待办/工作流主动推送） | https://github.com/volcengine/MineContext |
| 21 | **Khoj** | 本地可接 Ollama 的私有知识检索 + 多终端入口 + 定时研究自动化 | https://github.com/khoj-ai/khoj |
| 22 | **Second-Me** | 个人分层记忆建模（L0→L2）与本地私有模型微调“数字分身” | https://github.com/mindverse/Second-Me |
| 23 | **personal-ai-memory** | 极轻量 Chrome 浏览轨迹 + 个人本地记忆注入探索 | https://github.com/marswangyang/personal-ai-memory |
| 24 | **web-recap & Reading-Watch-List** | 浏览器阅读/待读列表抓取 + 本地 LLM 离线自动摘要汇总 | https://github.com/robzolkos/web-recap · https://github.com/swetas7/Reading-Watch-List-Extension-Local-LLM |

#### 2.4.1 MineContext (volcengine/MineContext)
- **仓库链接**：https://github.com/volcengine/MineContext
- **1. 核心解决的问题**：被动型知识库需要用户先想起来去搜才有用；忙碌一天结束后，散落的日常浏览、文档修改与未记下来的隐含待办往往直接被遗忘。
- **2. 使用的方法**：聚焦 **Proactive Context-Aware AI Partner**，持续抓取桌面端工作上下文碎片形成结构化 Context 切片，配合周期聚合与生命周期策略主动产出每日工作摘要、Todo 建议和相关提醒卡片。
- **3. 解决前后的对照**：**Before** — 晚上写工作总结对着二十几个杂乱标签页苦苦回忆；**After** — AI 根据后台收集的一天轨迹主动把“今天做完了什么、还剩什么待跟进”呈现在桌面。
- **4. 对「Context 补全计划」的提示与指示**：主动日报/提醒（`L4` Proactive Delivery）是非常自然的高价值产品出口，但应建立在低噪声多源事件（音频+剪切板+有效浏览）之上，作为基座稳固后的自然衍生应用，而不是开局即陷入高功耗全屏截屏。

#### 2.4.2 Khoj (khoj-ai/khoj)
- **仓库链接**：https://github.com/khoj-ai/khoj
- **1. 核心解决的问题**：已有大量 Obsidian/Markdown/PDF 私有文档时，既想用本地开源大模型隐私检索聊天，又希望每天/每周在常用软件里按计划自动运行梳理或调研。
- **2. 使用的方法**：支持自托管部署与本地 Ollama/开源模型接入，构建文档混合检索索引、多终端接入（Obsidian、Emacs、Web、桌面与常见通信端口），并支持配置后台定时执行的 **Automations**。
- **3. 解决前后的对照**：**Before** — 本地笔记库是静态只读文件夹，每次周期性整理都要人工开启会话手敲 Prompt；**After** — 随时从日常工具自然语言召回私有知识，例行总结由后台自动化安静完成。
- **4. 对「Context 补全计划」的提示与指示**：验证了**“夜间/周度定时巩固任务（Nightly Synthesis）”**的巨大价值——白天的轻量通道记录可在夜间空闲时集中合并为高质量 Episode 卡片与周报摘要，同时兼顾多入口无摩擦调用。

#### 2.4.3 Second-Me (mindverse/Second-Me)
- **仓库链接**：https://github.com/mindverse/Second-Me
- **1. 核心解决的问题**：单纯靠运行时检索碎片片段很难还原一个人的整体价值观、长期隐含认知框架与特有表达风格，且用户不愿把“完整数字自我”交给中心化云服务。
- **2. 使用的方法**：采用基于 HMM（Hierarchical Memory Modeling）的 **L0→L1→L2 个人记忆分层整理与 Me-Alignment 对齐机制**，允许用户在本地消费级设备上将长期个人经验整合进自有轻量化模型参数（AI Self），并探索安全可控的身份交互。
- **3. 解决前后的对照**：**Before** — 通用大模型即便挂载外部片段也仍像陌生的“临时外包客服”；**After** — 产生一个深度内化用户认知癖好且本地部署可控的个性化“数字分身”。
- **4. 对「Context 补全计划」的提示与指示**：明确了本计划的技术边界——**近期高速变化的日程、调试报错与刚说过的话应坚持结构化检索（Timeline + 图谱 + MCP），而非早早微调模型权重**；只有在攒够数月稳定风格语料后，微调层才作为长期偏好补充探索。

#### 2.4.4 personal-ai-memory (marswangyang/personal-ai-memory)
- **仓库链接**：https://github.com/marswangyang/personal-ai-memory
- **1. 核心解决的问题**：重型 Agent 记忆框架常要求部署图数据库+独立向量集群+队列服务，个人开发者往往只想用一个极轻量本地工具就把日常 Chrome 浏览上下文融进 AI 记忆。
- **2. 使用的方法**：以浏览器插件捕集日常上网轨迹，配合轻量本地后端完成提取整理和私有检索注入（据调研期仓库分析记录）。
- **3. 解决前后的对照**：**Before** — 为了让 AI 知道自己刚才看过的资料需要运维一套重型服务端或人工反复粘链接；**After** — 以最小运行依赖完成从浏览页面到私有 AI 记忆池的小步闭环。
- **4. 对「Context 补全计划」的提示与指示**：再一次提醒开源落地铁律——**如果安装部署需要超过五分钟或折腾多个重型外部服务，个人项目就会迅速失去真实使用率**；本仓核心工程 MVP 必须坚持零外部重依赖单机可直接跑通。

#### 2.4.5 web-recap (robzolkos/web-recap) & Reading-Watch-List-Extension-Local-LLM
- **仓库链接**：https://github.com/robzolkos/web-recap · https://github.com/swetas7/Reading-Watch-List-Extension-Local-LLM
- **1. 核心解决的问题**：日常打开几十个网页和存进待读清单的文章转眼就忘，同时又担心把全量浏览网页明文送给第三方云端 LLM 总结会暴露个人阅读偏好与内网/隐私内容。
- **2. 使用的方法**：将浏览器浏览聚合/待读抓取扩展与**完全跑在本机的轻量化 LLM（如 Ollama）**对接，自动抓取正文完成主题聚类、简报归纳与离线摘要，全程不出本机网络边界。
- **3. 解决前后的对照**：**Before** — 待读列表无限膨胀成焦虑黑洞，云端摘要有隐私和 API 费率顾虑；**After** — 一键或在后台零成本生成私密、可读的阅读回顾摘要。
- **4. 对「Context 补全计划」的提示与指示**：**用本地小模型做前端噪声过滤与初筛摘要**性价比极高——杂乱网页究竟是工具登录页还是干货长文、应该凝练成哪两句话进索引，完全交由本地小模型低成本消化，把云端强模型的注意力留给真正复杂的跨源综合推理。

---

## 三、 学术论文与评测基准索引与四维精读（16 篇）

> 完整独立归档版本见：[docs/research/papers-blogs-digest.md](docs/research/papers-blogs-digest.md)。以下同步展开每篇文献的四维精读（按调研检索状态如实保留个别检索注记）。

### 3.1 连续生活流与 Agent 长期记忆评测（7 篇）

| # | 论文 / 基准 | 核心考察维度 | 链接 / 标识 |
| :---: | :--- | :--- | :--- |
| 1 | **LifeDialBench** | 连续多模态生活流（Lifelog）与长程对话交织记忆评测 | [arXiv:2604.11182](https://arxiv.org/abs/2604.11182) |
| 2 | **STALE** | 记忆随时间演化失效（Memory Staleness）与新旧冲突抑制评测 | [arXiv:2605.06527](https://arxiv.org/abs/2605.06527) |
| 3 | **PM-Bench** | 个人长期记忆组织、压缩与个性化召回框架与基准 *(单一检索源注记)* | [arXiv:2607.12385](https://arxiv.org/abs/2607.12385) · [GitHub](https://github.com/genglinliu/PMBench) |
| 4 | **MemoryCD** | 连续动态输入下的冲突检测（Conflict）与长期稳定性评测 | [arXiv:2603.25973](https://arxiv.org/abs/2603.25973) |
| 5 | **From Memory to Action** | 从静态背诵（Recall QA）转向评估记忆对实际任务行动（Action）的贡献 | OpenReview *(无确认 arXiv 号)* |
| 6 | **LongMemEval** | 跨会话提取、时间推理、知识更新与不可回答拒答（Abstention） | [arXiv:2410.10813](https://arxiv.org/abs/2410.10813) |
| 7 | **LoCoMo** | 超长多会话连续对话（单跳 / 多跳 / 时间 / 摘要 / 多模态）评测 | [arXiv:2402.17753](https://arxiv.org/abs/2402.17753) |

#### 3.1.1 LifeDialBench (`arXiv:2604.11182`)
- **链接**：https://arxiv.org/abs/2604.11182
- **1. 核心解决的问题**：现有对话记忆基准只有孤立文本闲聊，无法检验 Agent 在日程、位置、声音、感知等连续非对话生活流（Lifelog）与多轮对话交织时的跨模态长程记忆力。
- **2. 使用的方法**：将多源异构生活流事件与跨天多轮对话时间线联合编排为基准测试集，系统考核跨模态关联、信息抽取、时间锚点对齐与更新追踪能力。
- **3. 解决前后的对照**：**Before** — 纯文本聊天能拿高分的系统在现实多渠道个人陪伴里常常“看不懂昨天的事和今天的对话有关”；**After** — 暴露并量化了平面纯文本 RAG 在跨源生活流上的明显短板。
- **4. 对「Context 补全计划」的提示与指示**：`L2` Episode 构建必须把同一时间窗里的**语音转写 + 剪贴板粘贴 + 浏览网页**交叉揉进同一个联合上下文单元，而不是各自隔离做孤岛检索引擎；同时借鉴其题型建个人脱敏回放评测集。

#### 3.1.2 STALE (`arXiv:2605.06527`)
- **链接**：https://arxiv.org/abs/2605.06527
- **1. 核心解决的问题**：记忆越积越多后不可避免充斥“曾经为真、现已过时”的旧事实（取消的会议、废弃的技术方案、变更的时间），通用基准几乎忽略测量“过时记忆抑制能力”。
- **2. 使用的方法**：设计专门包含状态覆盖、计划变更与历史时效演化的测试任务，直接对比朴素只增不改（Append-only）检索与带时效控制/覆写机制记忆的表现差距。
- **3. 解决前后的对照**：**Before** — 方案 A 与替换后的方案 B 向量相似度同样极高，大模型极易拿着旧决策当真；**After** — 明确证实显式时效约束与状态演化建模对防止“幻觉式考古”不可或缺。
- **4. 对「Context 补全计划」的提示与指示**：坚定践行 **“原始档案不可变（L0/L1）”与“知识状态可过期（L3）”分离**——L3 实体结论必须记录 `valid_from / valid_to / superseded_by`，过期节点在默认检索中降权或显式标 `[已失效/曾用]`。

#### 3.1.3 PM-Bench (`arXiv:2607.12385` · `genglinliu/PMBench`)
- **链接**：https://arxiv.org/abs/2607.12385 · https://github.com/genglinliu/PMBench *(注：`2607.12385` 编号在调研阶段仅见于单一检索结果集，正式引用前可再核验出版记录)*
- **1. 核心解决的问题**：早期记忆基准多关注短期对话片段抽事实，缺乏面向个人长期真实场景中偏好漂移、习惯归纳与海量碎片长期召回的标准化个人记忆基准。
- **2. 使用的方法**：构建跨周期个人长期记忆情景数据集与对应评测代码库（`PMBench`），检验系统在高时间跨度个人事件流下的组织、压缩和个性化检索有效性。
- **3. 解决前后的对照**：**Before** — 用几十条简短对话测出 95% 就自以为解决了个人记忆问题；**After** — 暴露出写入阶段结构切分粗糙在长周期下会被指数级放大的问题。
- **4. 对「Context 补全计划」的提示与指示**：不要只迷信调检索重排模型（Rerank）救场——**写入时的 Episode 边界整洁度、实体提取一致性与层级摘要品质直接决定了长期记忆上限**。

#### 3.1.4 MemoryCD (`arXiv:2603.25973`)
- **链接**：https://arxiv.org/abs/2603.25973
- **1. 核心解决的问题**：真实使用过程中记忆流是连续不断涌入并包含前后修正与矛盾的，只测静态建好库的离线测试难以测出持续运营后的**冲突积压与长期退化（Memory Degradation）**。
- **2. 使用的方法**：围绕持续增量更新、新旧陈述矛盾（Conflict/Contradiction）以及记忆容量扩大后的召回稳定性构建动态评估方法。
- **3. 解决前后的对照**：**Before** — 刚开始试用前几天惊艳好用，跑满三个月后库里自相矛盾条目成堆、命中率雪崩；**After** — 把“写入期/维护期持续消解冲突与去重合并”确立为与检索同等重要的核心工程指标。
- **4. 对「Context 补全计划」的提示与指示**：在架构上明确区分 **写入时指纹合并（如相同报错复制、反复切换同一文档）** 与 **夜间定时巩固/冲突消解队列**，防止系统随使用时长增长出现记忆退化。

#### 3.1.5 From Memory to Action (`OpenReview`)
- **来源**：OpenReview *(调研期确认收录，暂未对应到 arXiv 编号)*
- **1. 核心解决的问题**：传统记忆评测几乎都在考“问 Agent 过去某事答得对不对（Recall QA）”，但真实世界里我们需要的是“**记忆能否让 Agent 下一步工具调用与行动更准确高效**”。
- **2. 使用的方法**：把过往个人交互偏好与经验接入真实需要多步工具决策的下游行动评测任务，通过动作成功率与决策效率验证记忆模块的真实净增益。
- **3. 解决前后的对照**：**Before** — 许多系统为了 QA 指标死命堆砌无关背景塞满窗口，反而干扰当前工具选参，越记越笨；**After** — 扭转评测导向：好的记忆应当精准提供当下执行所需最小充分上下文。
- **4. 对「Context 补全计划」的提示与指示**：完美呼应本仓库英文名 **Context Instrumentality**——验证我们上下文引擎好坏的黄金测试不是“能不能背出前天录音”，而是 **“接到 Claude Code / 日常助手上后，是不是少追问了三轮背景且一次性正确改对代码”**。

#### 3.1.6 LongMemEval (`arXiv:2410.10813`)
- **链接**：https://arxiv.org/abs/2410.10813
- **1. 核心解决的问题**：传统“大海捞针（NIAH）”只考单次窗口里的原文照抄，完全考不出现实交互中跨越超多轮历史、需要**时间推算、状态更新追踪、多会话归因以及不知则拒答（Abstention）**的长期交互能力。
- **2. 使用的方法**：构造贴近真实人机协同的跨长周期多会话基准，重点围绕**信息提取、跨会话多跳推理、时间推理、知识更新与弃权拒答**五大核心能力对比不同索引粒度与检索增强架构。
- **3. 解决前后的对照**：**Before** — 拿单文档 128K 捞针跑分掩盖了“分不清事件前后顺序、认不出旧偏好被更新、没记住还爱胡编”的真实盲点；**After** — 成为业内检验 Zep、Mem0 等现代记忆系统的事实硬标准，实证了时间戳显式建模与检索结构优化的高回报。
- **4. 对「Context 补全计划」的提示与指示**：MCP 返回的每条上下文片断必须携带清晰的绝对与相对时间字段，拒绝纯裸文本块；同时设计严谨的空返回/低置信度协议，宁可明示“本地库未记录该事实”也不允许在摘要层臆造细节。

#### 3.1.7 LoCoMo (`arXiv:2402.17753`)
- **链接**：https://arxiv.org/abs/2402.17753
- **1. 核心解决的问题**：早期对话数据集轮次少、时间跨度短且缺少多模态与复杂因果线，缺乏评估超长个人历史多跳总结与时序对齐的标准沙盒。
- **2. 使用的方法**：采用基于人物设定与动态事件图驱动并经人工校验的方式，生成横跨数十个独立时间分散会话、数百轮次及多模态信息的多维度问答基准（覆盖单跳、多跳、时间推断、开放摘要等）。
- **3. 解决前后的对照**：**Before** — 窗口塞满几千字聊天似乎就能应付普通基准，掩盖了跨越几周的多点线索融合退化；**After** — 证明即便全历史塞进长上下文窗口，模型在多跳汇总与时间序定位上仍显著掉队，迫使社区转向结构化分层记忆。
- **4. 对「Context 补全计划」的提示与指示**：跨时间线汇总（例如“这周我多次在不同聊天和网页里琢磨的 X 方案进展”）是多跳+时间窗聚合问题，必须在 SQLite + 图谱层原生支持按时间区间聚类 + 主题摘要索引。

---

### 3.2 事件分割、情景记忆与系统架构（6 篇）

| # | 论文 | 核心机制与贡献 | 链接 |
| :---: | :--- | :--- | :--- |
| 8 | **EM-LLM** | 将事件分割理论（EST）化为惊奇度预测误差 + 边界精修 + 时空邻接两阶段召回 | [arXiv:2407.09450](https://arxiv.org/abs/2407.09450) |
| 9 | **Episodic Memory is the Missing Piece** | 辨析情景记忆与语义记忆：强调特定时空过程经验（Episode）不可被静态 Fact 取代 | [arXiv:2502.06975](https://arxiv.org/abs/2502.06975) |
| 10 | **Zep** | Episode / Semantic Entity / Community 三层时序感知图谱架构与低延迟混合召回 | [arXiv:2501.13956](https://arxiv.org/abs/2501.13956) |
| 11 | **Mem0** | Extract + `ADD/UPDATE/DELETE/NOOP` 动态压缩事实记忆 + 图增强 `Mem0g` | [arXiv:2504.19413](https://arxiv.org/abs/2504.19413) |
| 12 | **Nemori** | 基于认知自组织与预测偏差对齐的情景切分与记忆演化思路 *(标题-ID 部分核验)* | [arXiv:2508.03341](https://arxiv.org/abs/2508.03341) |
| 13 | **Memory for Autonomous LLM Agents** | 基于 POMDP 的 **Write – Manage – Read** 三轴形式化大综述 | [arXiv:2603.07670](https://arxiv.org/abs/2603.07670) |

#### 3.2.1 EM-LLM (`arXiv:2407.09450`)
- **链接**：https://arxiv.org/abs/2407.09450
- **1. 核心解决的问题**：面对近乎无限流式延伸的长上下文，机械按固定 512 Token 或固定分钟切块会强行腰斩完整思维与场景，导致碎片化召回丢掉前后连贯性。
- **2. 使用的方法**：将认知心理学 **事件分割理论（EST）** 引入大模型，依托模型自身对下文预测的**意外度峰值（Bayesian Surprise / 预测误差）**配合注意力图边界面精修动态划分 **Episodic Events**；检索时采用“语义向量初筛定位 + 相邻连续时空片段扩展召回”两阶段组装。
- **3. 解决前后的对照**：**Before** — 固定字数切分经常命中半句莫名其妙的话，丢头少尾；**After** — 记忆块天然紧贴话题/事件自然转折点，召回时顺带拉回邻接前因后果，显著改善长流连贯推理。
- **4. 对「Context 补全计划」的提示与指示**：明确弃用“每 N 分钟一刀切”的机械分片！`L1 → L2` 应综合利用 **静音间隔 + AFK + 窗口/工程切换 + 主题变化** 确定天然 Episode 边界；MCP 应提供类似 `get_episode_neighbors` 的前后文延伸接口。

#### 3.2.2 Episodic Memory is the Missing Piece for Long-Term LLM Agents (`arXiv:2502.06975`)
- **链接**：https://arxiv.org/abs/2502.06975
- **1. 核心解决的问题**：当前大量记忆框架只知道从对话里抽干巴巴的静态事实三元组（Semantic Facts），把完整发生经过全丢了，结果 Agent 学不会人类那种结合特定时间、场合与试错过程的“长记性”。
- **2. 使用的方法**：作为概念架构与立场论文，清晰厘清**语义记忆（一般性常识/个人稳定属性）、情景记忆（一次具体时空事件的完整经历与决策结果）与程序记忆**的界限，主张把情景记忆独立建层并与语义记忆双向巩固而非压扁替代。
- **3. 解决前后的对照**：**Before** — 记忆里只剩“用户改了配置文件”，被追问“周二下午为啥改失败了以及中间试了哪条命令回滚”则一问三不知；**After** — 确立了必须保留时空锚定过程情景（Episode）作为长期 Agent 反思与避坑基础的理论准则。
- **4. 对「Context 补全计划」的提示与指示**：**直接确立本仓库 `L2`（情景事件包）与 `L3`（语义事实/图谱）并存不互删的核心建筑法则**——永远用 `L2` 保存具体那场会议、那次 Debug 的过程证据，只让 `L3` 从中提炼高频当前状态。

#### 3.2.3 Zep (`arXiv:2501.13956`)
- **链接**：https://arxiv.org/abs/2501.13956
- **1. 核心解决的问题**：静态分块向量库既无法进行跨实体的复杂多跳关联推理，又无法忠实反映现实事实随时间演进的动态新旧替代，全上下文输入则成本过高。
- **2. 使用的方法**：以 **Graphiti** 引擎构建三层子图联动体系：**Episode 子图**（原始对话/事件保真节点）→ **Semantic Entity 子图**（携带双时序有效边界 `t_valid` / `t_invalid` 的动态边，增量写时检测冲突标废旧关系）→ **Community 子图**（高层聚簇概括），并在查询时结合向量、关键词与图遍历快速组装精炼上下文。
- **3. 解决前后的对照**：**Before** — 遇到实体状态变更和多跳时序问题时准确率低，塞全历史对话延迟与算力暴增；**After** — 用远低于全历史窗口的极紧凑上下文延迟和成本，同时实现强时序感知、可追溯至原文 Episode 的结构化记忆召回。
- **4. 对「Context 补全计划」的提示与指示**：`Episode → Entity → Community` 三层逐级抽象且边边可反向溯源的架构，可直接作为本仓后续演进知识图谱层（`L2/L3`）的蓝图模板；写时增量抽图异步推进以免卡住实时采集。

#### 3.2.4 Mem0 (`arXiv:2504.19413`)
- **链接**：https://arxiv.org/abs/2504.19413
- **1. 核心解决的问题**：全历史对话直接送进模型窗口既昂贵又高延迟，而朴素把提取出来的碎片一直往库里追加又会迅速积累矛盾冲突与大量同义废话。
- **2. 使用的方法**：通过“上下文候选事实提取 + 与既有最相近历史条目比对执行 `ADD / UPDATE / DELETE / NOOP` 原子操作”的紧致管理流水线，同时提供纯向量版与引入实体三元组的图增强变体 `Mem0g`，将个人核心事实池维持在极精炼尺寸。
- **3. 解决前后的对照**：**Before** — 全历史推理延迟和 Token 消耗极高，简单增量叠加向量库准确率随冲突升高而下滑；**After** — 每次对话只需注入少量高纯度浓缩事实卡，极大削减上下文冗余并兼顾状态一致性。
- **4. 对「Context 补全计划」的提示与指示**：非常适合用来持续维护 `L3` 的轻量**“当前用户状态与核心偏好卡片”**（随手喂给 IDE 或聊天开场白）；但切记 `UPDATE/DELETE` 只能作用于衍生视图卡片，绝不能擦除 `L0/L1` 历史源记录。

#### 3.2.5 Nemori (`arXiv:2508.03341`)
- **链接**：https://arxiv.org/abs/2508.03341 *(注：标题与 arXiv 编号精确对应关系在调研期内为部分核验状态)*
- **1. 核心解决的问题**：常见的按时间轮次死板批量总结会不断把旧记忆里已知道的重复信息再嚼一遍，缺少根据认知预测误差自动发现边界和调整重点的机制。
- **2. 使用的方法**：延续认知心理学视角，探索基于语义边界对齐与“预测-校准（Predict-Calibrate）”原则的自组织记忆整理思路，围绕事件自然边界和超出预期的新增信息增量调整记忆表征。
- **3. 解决前后的对照**：**Before** — 定期流水账汇总导致记忆摘要高度同质重复、真正意外的决策转折点被淹没；**After** — 把总结和记录预算集中投放到“真正超出既有认知预期的新增变化”上。
- **4. 对「Context 补全计划」的提示与指示**：为我们的多传感器引入 **“信息增益门槛”** 提供了灵感——高频但重复无新意的桌面状态脉冲不需进 LLM 摘要，只有引入新实体、报错变更或决策转折的信号才值得升格重点提炼。

#### 3.2.6 Memory for Autonomous LLM Agents (`arXiv:2603.07670`)
- **链接**：https://arxiv.org/abs/2603.07670
- **1. 核心解决的问题**：各类 Agent 记忆研究路线纷繁芜杂（RAG、图谱、OS 分页、长上下文、参数化记忆等），缺乏一套严谨形式化的统一概念骨架用于对比设计与查漏补缺。
- **2. 使用的方法**：借助部分可观测马尔可夫决策过程（**POMDP**）视角形式化智能体记忆，沿着 **Write（写入表征）– Manage（内部整合、冲突整理、遗忘）– Read（查询检索、上下文注入）** 三大生命周期轴全面综述存储载体、运作机制与评测标准。
- **3. 解决前后的对照**：**Before** — 工程选型往往局限于“用哪个向量库/要不要上图谱”的局部拼凑，忽视记忆生命周期中间的维护与淘汰机制；**After** — 提供端到端三轴核对清单，能系统诊断任何个人记忆方案到底弱在 Write、Manage 还是 Read。
- **4. 对「Context 补全计划」的提示与指示**：建议作为本仓库架构评审标准清单——每隔一段时间用 `Write / Manage / Read` 三轴检视：采集端够不够省心纯净（Write）、夜间聚类和过时消除是否健全（Manage）、给 Agent 的 MCP 接口是否足够切题（Read）。

---

### 3.3 经典奠基文献（3 篇）

| # | 文献 | 学科与奠基贡献 | 来源 |
| :---: | :--- | :--- | :--- |
| 14 | **Personal Knowledge Graphs: A Research Agenda** | 正式定义以“我”为中心、融合私有+公共实体的 PKG 四大特征与纲领 | Balog & Kenter, *ICTIR 2019* · [DBLP](https://dblp.org/rec/conf/ictir/BalogK19) (`DOI:10.1145/3341981.3344241`) |
| 15 | **Event Segmentation Theory (EST)** | 揭示“预测误差骤升驱动人类自然事件边界切分”的认知心理学第一原理 | Zacks et al., *Psychological Bulletin 2007* |
| 16 | **MyLifeBits & Lifelog Search Challenge (LSC)** | 二十年终身全量数字化实验与交互式生活流极速检索竞赛基石 | Gemmell et al., *CACM 2006* · [lifelogsearch.org](http://lifelogsearch.org/) |

#### 3.3.1 Personal Knowledge Graphs: A Research Agenda (Balog & Kenter, *ICTIR 2019*)
- **文献链接**：`DOI:10.1145/3341981.3344241` · https://dblp.org/rec/conf/ictir/BalogK19
- **1. 核心解决的问题**：在通用公共知识图谱（Wikidata 等）蓬勃发展的年代，学界一直缺乏对“**围绕单一个体、私密、结构化且跨多源融合的个人知识网络（PKG）**”的系统定义与研究路线图。
- **2. 使用的方法**：通过信息检索领域视角提出个人知识图谱（PKG）清晰界定，刻画其核心属性——以用户为绝对主体中心（Egocentric）、私有实体与公共知识链接共生、多源融合与全生命周期持续演化。
- **3. 解决前后的对照**：**Before** — 个人数字资料只是孤立无关联的文件夹与通信录条；**After** — 提供了将联系人、项目、地点、对话与公开概念统一锚定进个体关系网的长期学术纲领。
- **4. 对「Context 补全计划」的提示与指示**：无论前端接回多少渠道，最终沉淀到 `L3` 图谱层都要**收敛在统一的个人主键（人物/项目/工作区实体消歧）**上——例如语音里喊的小张、剪贴板里的邮箱、Git 提交名必须能对齐到同一个 `Person` 实体节点。

#### 3.3.2 Event Segmentation Theory (EST) (Zacks et al., *Psychological Bulletin* 2007)
- **1. 核心解决的问题**：现实感知在物理时间上是一条连续流（Stream），并没有天然的分段标点，人类认知系统是如何自发将其拆解成一件件边界清晰、可以事后回忆的事件（Events）的？
- **2. 使用的方法**：结合认知实验与神经成像证据提出事件分割理论——大脑持续维持“工作事件模型”来预测下一瞬状态；当环境变化导致**预测误差（Prediction Error）**瞬间飙升时（人物更替、空间切换、核心目标改变），工作模型重刷新立，旧段落封存为离散边界事件。
- **3. 解决前后的对照**：**Before** — 找不到非主观拍脑袋的科学依据解释“一件事何时结束、下一件事何时开始”；**After** — 建立了直接贯穿至现代 `EM-LLM` 与 `Nemori` 的计算边界切分第一性原理。
- **4. 对「Context 补全计划」的提示与指示**：本仓库将 **多渠道信号合流切成 `Episode`** 时可以直接套用这套廉价物理启发特征：一旦捕获到“AFK 停顿 / 活跃 App 或 Repo 切换 / 录音说话人或主题突变”，往往就等价于一次低成本高准确率的人类认知边界触发点。

#### 3.3.3 MyLifeBits & Lifelog Search Challenge (LSC) (*CACM 2006* / `lifelogsearch.org`)
- **来源链接**：*Communications of the ACM* 2006 · http://lifelogsearch.org/
- **1. 核心解决的问题**：先驱性地直面“如果我们尝试把一个人阅读的一切、拍摄的照片、通话录音、浏览记录与文件**终身全量留存**，系统究竟会死在哪里、真正难在哪里？”
- **2. 使用的方法**：`MyLifeBits` 作为 Gordon Bell 主导的多媒体终身档案先驱工程，探索统一持久 ID、属性标注、跨媒体引用链与关联存储；后续 **LSC 国际年度评测竞赛** 则进一步用海量穿戴设备照片+生物/定位/数字日志持续检验交互式极速检索方法。
- **3. 解决前后的对照**：**Before** — 个人记忆全部存在脆弱纸张、散落硬盘和人脑模糊印象里，停留在 Memex 哲学畅想；**After** — 二十年长期系统运行得出铁一般实证结论：**“采存下来”并不难，“免维护高可用检索与日常融入习惯”才是生死分水岭**。
- **4. 对「Context 补全计划」的提示与指示**：少走二十年弯路的核心戒律——**绝不要为了采集而采集，先建好“最小阻力落盘 + 高效检索出口 + 合理隐私降噪”再扩传感器**，杜绝制造只写入不消费的数字垃圾山。

---

## 四、 技术博客、工程报告与系统规范（6 篇）

| # | 来源与标题 | 核心结论与工程定位 | 原文链接 |
| :---: | :--- | :--- | :--- |
| 1 | **Anthropic Engineering**：Effective context engineering for AI agents | 从 Prompt 转向上下文预算工程：最小高信噪比集合 + 按需检索（Just-in-Time） | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents |
| 2 | **Chroma Technical Report**：Context Rot | 实证揭示输入无关上下文与相似干扰项增多会导致 LLM 推理显著退化 | https://research.trychroma.com/context-rot |
| 3 | **Karlicoss (`beepb00p.xyz`)**：HPI / Promnesia / Exobrain 系列工程文集 | Local-first、保留不可变源、低维护抗腐化的十年期个人基础设施心法 | https://beepb00p.xyz/ |
| 4 | **Simon Willison**：Personal Data Warehouses: Reclaiming Your Data | 用微 CLI 采集器 + 单文件 SQLite + Datasette 零运维搭个人数据仓库 | https://simonwillison.net/2020/Nov/14/personal-data-warehouses/ |
| 5 | **nspasteboard.org & Apple macOS 15.4+**：`NSPasteboard.accessBehavior` | 跨密码管理器剪贴板保密标记标准与现代 macOS 系统权限隐私边界 | http://nspasteboard.org/ · https://developer.apple.com/documentation/appkit/nspasteboard · https://mjtsai.com/blog/ |
| 6 | **浏览器有效停留三层信号规范**：Chrome `idle` + `windows.onFocusChanged` + MDN `Page Visibility API` | 三重正交信号交叉过滤后台空挂标签页，识别真正产生阅读注意力的有效页面 | https://developer.chrome.com/docs/extensions/reference/api/idle · https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API |

### 4.1 Anthropic Engineering: Effective context engineering for AI agents
- **原文链接**：https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- **1. 核心解决的问题**：随着智能体进入长程多步自主执行，团队若继续沿用“拼命把所有规矩和全部历史往 Prompt 里堆”的粗暴做法，极易导致上下文膨胀超限且模型核心指令注意力遭到稀释。
- **2. 使用的方法**：将实践升格为 **Context Engineering（上下文工程）**，核心目标是永远筛选**“实现预期行为的最小高信号 Token 集合”**，并归纳四大武器：动态对话压缩（Compaction）、外部结构化笔记（Scratchpad）、**工具化即时检索（Just-in-Time Retrieval）** 与多子智能体上下文隔离。
- **3. 解决前后的对照**：**Before** — 盲目往大窗口里全量灌注静态文本，模型越读越慢、越读越乱；**After** — Context 从一坨静态字符串变为需要精确调度的稀缺实时注意带宽资源。
- **4. 对「Context 补全计划」的提示与指示**：直接为本计划敲定工具契约哲学——我们的系统不是往用户所有对话开头预塞十万字录音摘要，而是为智能体提供高浓缩索引 + 精准 **Just-in-Time MCP 工具** 按需索取片段。

### 4.2 Chroma Technical Report: Context Rot: How Increasing Input Tokens Impacts LLM Performance
- **原文链接**：https://research.trychroma.com/context-rot
- **1. 核心解决的问题**：随着模型上下文上限动辄达到几十万乃至百万 Token，行业存在普遍幻觉——“反正窗口装得下，不如把所有原始资料直接堆进去让大模型自己翻，还要什么记忆检索和分层？”
- **2. 使用的方法**：通过设计受控长上下文基准，系统性调节输入 Token 总长、无关/近义干扰项（Distractors）数量与关键线索位置，评测主流开源与闭源大模型的检索与推理准确度随输入变长的衰减曲线。
- **3. 解决前后的对照**：**Before** — 迷信百万上下文窗口“全塞即万能”而轻视去噪整理；**After** — 实证揭示即便远未撑破最大窗口上限，大量无关与近义混淆上下文仍会引起模型推理可靠性显著下降（**Context Rot，上下文腐烂**）。
- **4. 对「Context 补全计划」的提示与指示**：这是本项目存在最硬核的技术依据——直接把杂乱的语音流水账、成千上万条无用剪贴板拷贝和重复网页塞进模型只会诱发 Context Rot；**必须经过去重、分割（Episode）、时效过滤与精准精选后注入**。

### 4.3 Karlicoss (`beepb00p.xyz`): HPI / Promnesia / Exobrain 系列工程文章
- **原文链接**：https://beepb00p.xyz/
- **1. 核心解决的问题**：大量个人黑客项目写完三个月后因为过于沉重、格式演化或维护疲劳便彻底废弃，开发者迫切需要一套能安稳跑过五到十年的个人数字基建原则。
- **2. 使用的方法**：通过大量一线自用复盘沉淀出高度克制的架构纪律：**Local-first 与 Plaintext/SQLite 优先、原始采集导出文件保持只追加不可变、用薄适配器层（HPI）隔开源与算力演化、有清晰实用日常出口后再持续滚雪球扩展数据源**。
- **3. 解决前后的对照**：**Before** — 开局画巨型分布式架构图，未接通第二个通道就已经被繁杂维护压垮；**After** — 经得起数年时间考验、换模型或换电脑都能丝滑续命的真实可运行外脑基座。
- **4. 对「Context 补全计划」的提示与指示**：作为防止过度设计（Anti-Overengineering）的定海神针——先保好手头最核心高价值的录音与剪切板两三条真数据源，确保 `L0` 干净持久，绝不因早期贪大求全拖垮工程节奏。

### 4.4 Simon Willison: Personal Data Warehouses: Reclaiming Your Data
- **原文链接**：https://simonwillison.net/2020/Nov/14/personal-data-warehouses/
- **1. 核心解决的问题**：个人产出在各个互联网平台留下大量足迹，普通开发者却常以为把它们收回自己手里做查询分析需要高昂的大数据数仓技术栈门槛。
- **2. 使用的方法**：推广 **单文件 SQLite 个人数据仓库 + 专用微 CLI 采集脚本 + Datasette** 轻量组合：每条通道通过独立极简命令行工具同步落入标准化 SQLite 表，立刻享用关联查询、全文检索（FTS5）和开放 HTTP/JSON 出口。
- **3. 解决前后的对照**：**Before** — 觉得个人数据中台等同于运维重型分布式数仓与搜索集群而望而却步；**After** — 一名开发者在一个周末里用数十行 Python 和单文件 SQLite 就能建立终身受用的私人数据查询库。
- **4. 对「Context 补全计划」的提示与指示**：确定本项目现阶段的最小可运维技术栈选型（**单机 SQLite + FTS5 + 本地向量扩展/检索**）——让社区任何使用者都能 `git clone` 后五分钟内零重型数据库部署跑通整套流程。

### 4.5 `nspasteboard.org` 与 macOS 15.4+ `NSPasteboard.accessBehavior` 剪贴板规范
- **参考链接**：http://nspasteboard.org/ · https://developer.apple.com/documentation/appkit/nspasteboard · https://mjtsai.com/blog/
- **1. 核心解决的问题**：剪贴板是极佳意图通道，但如果采集程序对复制进剪贴板的一切无差别静默保存，不仅会误存密码管理器里的一次性密码、API 密钥，还会与 macOS 15.4+ 日趋严格的剪贴板隐私授权拦截产生冲突。
- **2. 使用的方法**：严格遵循社区 **`nspasteboard.org` 扩展类型标记规范**（主动忽略带有 `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` 标识的内容以及密码管理工具来源），并适配 Apple macOS `NSPasteboard` 现代访问行为/隐私权限模型（检测与规范引导授权而非硬绕限制）。
- **3. 解决前后的对照**：**Before** — 剪切板历史工具一不小心把明文密码和密码卡号存进模型回忆，同时在新版 macOS 下疯狂弹权限警示；**After** — 源头即完成高敏凭证绝缘隔离，合乎系统安全设计合规长期运行。
- **4. 对「Context 补全计划」的提示与指示**：`ClipContext` 及后续一切桌面端工具的不可逾越安全红线——**敏感标记拦截与排除列表必须在写入 `L0` 磁盘前执行，绝不允许先落盘再事后删**。

### 4.6 浏览器有效停留三层信号规范（Chrome `idle` + `windows.onFocusChanged` + MDN `Page Visibility API`）
- **参考链接**：https://developer.chrome.com/docs/extensions/reference/api/idle · https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API
- **1. 核心解决的问题**：简单监听 `history` 或 `tabs.onUpdated` 会收进海量后台静默加载页、秒关页和挂机一整晚的空开标签页，造成“伪阅读时长”彻底污染上下文权重排序。
- **2. 使用的方法**：将浏览器三大官方正交信号组合为 **“真正在看（Active Attention）”** 复合门控：**`Page Visibility API`**（确认处于当前标签前台 `visible`）∩ **`chrome.windows.onFocusChanged`**（确认浏览器窗口处于 OS 前景焦点中）∩ **`chrome.idle`**（确认用户键鼠未离开进入 `idle/locked` 状态）。
- **3. 解决前后的对照**：**Before** — 随手点开丢在后台吃灰三天的网页反而占据时间统计榜首，真正精读三分钟的技术文档淹没在跳转流水里；**After** — 仅当连续有效停留跨过设定时间阈值（或发生复制/高亮互动）时才触发 `Defuddle/Readability` 提取正文归档。
- **4. 对「Context 补全计划」的提示与指示**：作为未来建设本仓库 `channels/browser/` 扩展采集端的精确准入门控规范，在源头就拦截绝大多数网页流水账噪声，兼顾极高文本质量与极低后续 LLM 摘要成本。

---

## 五、 仓库结构与已接入采集端

```text
context-instrumentality-project/
├── README.md                              # 研究型项目首页索引与全量四维精读手册
├── ROADMAP.md                             # 分阶段演进路线图
├── CONTRIBUTING.md                        # 开源协作指南
├── assets/
│   └── eva-context-banner.png             # EVA 档案风项目顶图（極秘 · CONTEXT 补全计划）
├── docs/
│   ├── github-projects-setup.md           # GitHub Issues / Project 看板初始化指南
│   ├── rfc/
│   │   └── 0001-context-integration.md    # RFC-0001：个人多源 Context 整合架构与分层规范
│   └── research/
│       ├── projects-digest.md             # 24 项开源项目四维精读完整归档
│       ├── papers-blogs-digest.md         # 16 篇论文 + 6 篇博客与规范四维精读完整归档
│       ├── channels.md                    # 12 条 Context 采集渠道优先级、信噪比与可行性分析
│       ├── integration-methods.md         # 11 个先驱系统横向对比与 L0–L4 整合方法研究
│       ├── channel-audio.md               # 音频采集端 record-for-agent 架构与缺口调研
│       ├── channel-clipboard.md           # 剪切板采集端 ClipContext 设计与 MCP 梳理
│       └── landscape.md                   # Dark Context 概念与生态版图初稿
├── schema/
│   ├── README.md                          # 事件规范说明
│   └── context-event.schema.json          # L1 统一 ContextEvent JSON Schema
├── channels/
│   ├── README.md                          # 多渠道采集总览与接入约束
│   ├── audio/record-for-agent/            # 已合入：macOS 低功耗多源录音与状态采集原型
│   ├── clipboard/clipcontext/             # 已合入：macOS 剪切板历史与 MCP 检索原型（含 README）
│   ├── browser/README.md                  # 规划中：三层有效停留 + Defuddle/Readability 正文采集
│   ├── window/README.md                   # 规划中：桌面应用焦点与 AFK 状态区间采集
│   └── ai-chat/README.md                  # 规划中：跨 AI 工具对话轨迹归档与回流
├── hub/
│   └── README.md                          # 规划中：L1 SQLite/FTS5 底座 + L2 Episode 聚合 + MCP 出口
├── project/
│   └── issues.json                        # Roadmap 种子 Issue 列表
├── scripts/
│   └── bootstrap_github.py                # 批量同步 GitHub Project / Issues 辅助脚本
└── tests/
    └── test_bootstrap_github.py           # 自动化脚本单元测试
```

### 项目协作与许可证

- 研发任务拆解、里程碑与开源协作方式见 [ROADMAP.md](ROADMAP.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 与 [docs/github-projects-setup.md](docs/github-projects-setup.md)（配合 [project/issues.json](project/issues.json) 与 [scripts/bootstrap_github.py](scripts/bootstrap_github.py)）。
- 开源许可证（License）将在进入稳定代码协同与外部插件生态阶段前补充确定。
