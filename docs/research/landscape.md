[🏠 首页索引](../../README.md) ｜ [📡 采集渠道调研](channels.md) ｜ [🧩 整合方法与架构](integration-methods.md) ｜ [📦 开源项目精读](projects-digest.md) ｜ [📄 论文与博客精读](papers-blogs-digest.md) ｜ [🎙️ 音频通道](channel-audio.md) ｜ [📋 剪切板通道](channel-clipboard.md)

# 早期全景调研（立项初稿归档）

> [!NOTE]
> **归档定位说明**：本文档为本项目**立项阶段最初梳理的生态全景与方向初稿**（文中部分开源项目 star 量级参考搜索均值、未逐一人工复核）。所有最终核实后的结论、渠道优先级与 `L0 → L4` 架构决策，请以 [**采集渠道调研 (channels.md)**](channels.md)、[**整合方法研究 (integration-methods.md)**](integration-methods.md) 以及首页四维精读为准。
>
> **原始研究目标**：为构建“开源 Agent Context 补全计划”梳理学术依据、开源生态版图空白、端侧采集可行性边界（macOS / 浏览器 / 移动端 / 录音硬件）、隐私合规红线与早期参考架构蓝图。

---

## 一、 核心问题定义：为什么 Agent 需要“Context 补全计划”？

当前主流 AI Agent（Cursor、Claude、OpenClaw 等）的交互范式本质上是**“输入框驱动的孤岛式协作”**——每次新任务开始，用户都必须手动搬运背景：
- 刚在线下用硬件录下的口头讨论；
- 刚刚在不同软件间复制粘贴的报错、单号或灵感片段；
- 花了 5 分钟精读并划重点的技术博客；
- 手机通知栏刚刚弹出的日程变更、物流或消息摘要。

这些对用户意图至关重要、但当前 Agent 默认完全看不见的数据，统称为 **Dark Context（隐式 / 盲区上下文）**。

本项目的核心价值不在于“再造一个聊天记忆库”，而在于：**打通被 OS 权限、应用孤岛与物理空间割裂的高信噪比信号，通过跨模态时间线缝合与缺口补全，成为所有 Agent 通用的外部“感知海马体”。**

---

## 二、 学术界与 Benchmark 前沿洞察（早期整理脉络）

> 下列洞察后来全部收编进统一四维精读库（参见 [papers-blogs-digest.md](papers-blogs-digest.md) 查证核实后状态与检索注解）：

### 1. 过度有损压缩反而伤害性能（*LifeDialBench*, `arXiv:2604.11182`）
- **研究内容**：针对可穿戴设备与环境感知的连续日常对话评估（包含真实第一视角数据与模拟长程流），引入严格的时间因果在线评测协议。
- **核心反直觉发现**：在连续环境流场景下，**许多复杂的“高级摘要压缩型”记忆系统反而跑不过保留原始粒度的简单 RAG 基线**。原因在于早期的有损摘要会丢掉当下看似无关、但几天后才显现关联的细节。
- **架构启示**：**原始证据链不可丢弃**。应采用“原始高精度事件层（Raw Event Store）+ 可演进摘要层（Episode / Semantic Layer）”的双层设计，而不是用摘要直接覆盖原始记录。

### 2. 隐式状态冲突是最大杀手（*STALE*, `arXiv:2605.06527`）
- **研究内容**：测试“隐式冲突（Implicit Conflict）”——即生活中新的环境事件悄悄推翻了旧状态，而用户从未显式宣布“请忘记旧记忆”（例如：上周刚说在调研方案 A，这周录音里一直在改方案 B 的代码）。
- **核心发现**：即便最前沿的大模型，在用户个人状态自然随时间推移的场景下，状态更新与推理准确率也仅约 **55%** 左右。
- **架构启示**：每条 Context 必须带**严格的时间戳、生命周期（TTL / Valid-From / Valid-To）与状态演进边**，不能把半年前的剪贴板和今天的网页精读混在同一个扁平向量库里检索。

### 3. 瓶颈在于“注意力权重与利用”，而非“存不下”（*MemoryCD* & *From Memory to Action*）
- **研究发现**：跨领域长期记忆的主要失效原因不是检索不到，而是**低价值噪声淹没了高意图信号**，且最大掉点卡在“记忆可用之后、转化为动作之前”。
- **架构启示**：采集端必须计算 **Attention Weight（注意力权重）**——在网页停留 3 秒误点关闭的权重接近 `0`，精读几分钟且伴随复制高亮动作的权重远高于偶然路过。

### 4. 前瞻性记忆（*PM-Bench*）
- **研究内容**：评估 Agent 在未来某个正确时间点或场景线索出现时，主动想起并触发未完成意图的能力（Prospective Memory）。
- **架构启示**：这正是**“补全计划”**高阶形态的理论支撑——不仅被动回答，还能在检测到“你打开了某项目但昨天录音里提到的风险还没解决”时主动提示。

---

## 三、 GitHub 开源生态全景与空白分析（立项初稿对照）

> **注意**：下表 Star 数量级为立项初稿检索期估算印象值（未逐仓库验证），仅供体会生态分工定位参考。

| 层次 | 代表开源项目 | 生态定位 | 核心强项 | 明显短板 / 留给我们的空间 |
| :--- | :--- | :--- | :--- | :--- |
| **感官采集层** | [screenpipe](https://github.com/screenpipe/screenpipe) | ~22k+ 级 *(注: 现已转商用许可)* | Rust 底座，24/7 本地桌面录屏 OCR + 音频 + MCP | 资源占用偏高；不抓浏览器精确停留与正文 DOM；无移动端融合 |
| | [BasedHardware/omi](https://github.com/BasedHardware/omi) | ~13k–14k+ 级 | 开源 AI 可穿戴硬件 + 环境对话转写与总结 | 偏重纯语音生态，与桌面剪贴板、代码、浏览器阅读等工作流割裂 |
| | [ActivityWatch](https://github.com/ActivityWatch/activitywatch) | ~19.6k 级 | 隐私优先的跨平台窗口/网页 Dwell Time 统计 | 只记“标题和时长”，**不抓网页正文、不抓剪贴板内容、不做 AI 语义缝合** |
| | [Freika/dawarich](https://github.com/Freika/dawarich) | ~10.9k 级 | 自托管位置历史（Google Timeline 替代） | 仅解决地理轨迹，未与日常语义事件关联 |
| **数据统一层** | [HPI](https://github.com/karlicoss/HPI) & [promnesia](https://github.com/karlicoss/promnesia) | ~1.6k / ~1.9k 级 | 极客级个人数据 Python 抽象层与浏览器历史侧边栏 | 偏脚本批处理和静态导出，缺少实时流、MCP 出口与语音端接入 |
| | [timelinize](https://github.com/timelinize/timelinize) | ~3.7k 级 | 多账户数据拉取归档到本地统一时间线 | 侧重历史归档，而非实时面向 Agent 的活体上下文供给 |
| **记忆基础设施** | [OpenViking](https://github.com/volcengine/OpenViking) | 高关注项目 | 虚拟文件系统（`viking://`）分层加载与演进 | 定位通用 Agent Context DB，**不包含端侧多源生活采集器** |
| | [mem0](https://github.com/mem0ai/mem0) / [graphiti](https://github.com/getzep/graphiti) / [cognee](https://github.com/topoteretes/cognee) / [letta](https://github.com/letta-ai/letta) | 主流记忆基础设施群 | 成熟记忆抽取、双时序图谱、有状态 Agent | 大多假设“输入已经是干净对话文本”，**缺少前端真实高信噪比采集链** |
| **上层应用** | [khoj](https://github.com/khoj-ai/khoj) / [MineContext](https://github.com/volcengine/MineContext) | 主流个人脑应用 | 第二大脑 RAG 与主动式桌面洞察 | 与自研录音硬件及自定义细粒度端侧信号扩展耦合较固定 |

> [!TIP]
> **早期洞察总结（生态甜区 Sweet Spot）**：下游记忆数据库与图引擎已经很丰富，真正稀缺的是上游**高信噪比多模态现实感知采集与跨源时间线缝合**（把音频、剪贴板、真实网页精读用一致结构通过开放 MCP 喂给任意 Agent）。

---

## 四、 四大核心采集源早期技术调研笔记

### 1. 录音硬件与离线语音（线下对话 Context）
- **推荐本地/边缘处理管线**：
  - **传输与切片**：硬件端或手机端尽量先做 **VAD（语音活动检测）**，只上传/保存有效人声片段，大幅减少无效静音和功耗。
  - **中文/中英混杂最佳开源 ASR**：阿里 **`FunASR` + `SenseVoice`** 生态（低延迟、原生支持中粤英等多语种与情感/事件标签）；追求零沉重 Python 环境或跨端端侧推理时可用 **`sherpa-onnx`** 跑量化模型。
  - **说话人分离（Diarization）**：区分“用户本人（Self）”与“他人（Speaker_X）”是决定录音对决策有多大参考价值的关键一跳（如结合 FunASR 生态的 `CAM++` 或 `sherpa-onnx` 说话人聚类模型）。

### 2. 用户剪贴板 + 前台上下文（高意图微动作）
- **核心原则**：没有来源上下文的剪贴板记录是不完整的，每次捕获应尽量携带 `{ content, content_type, source_app_name, source_bundle_id, window_title, timestamp }`。
- **macOS 系统要点**：轮询 `NSPasteboard.general.changeCount` + `NSWorkspace` / AX API 读窗口标题，并严谨合规适配 `macOS 15.4+ NSPasteboard.accessBehavior` 及 `nspasteboard.org` 协议（详规见 [channels.md](channels.md)）。
- **本地三层隐私防线**：① 密码管理器来源黑名单直接内存跳过（Zero-Touch Skip）；② 凭证与高熵 Secret 正则拦截（`sk-...` / JWT / 验证码等）；③ 可选 PII 脱敏或锁死为 `L2_LOCAL_ONLY` 不出本机。

### 3. 浏览器有效停留（Dwell Time）+ 正文
- **不直接只读浏览器 `History` 表原因**：只有打开瞬间的网址和标题，完全不知道**停了多久、是否前台真正在看、更没有网页正文**。
- **推荐三层过滤 + 抽取模式**：`visibilityState` + `windows.onFocusChanged` + `chrome.idle` 联合累计真正专注时间 → 达到阈值或发生复制动作后由 **`Defuddle`** 转为清洁 Markdown 入库（详情与取舍见 [channels.md](channels.md)）。

### 4. 手机端外延信号与物理场景标签
- **Android**：推荐利用合规官方 `NotificationListenerService` 读取消息/物流/提醒通知，并配合分享菜单入口；仅作备选探索 Shizuku 路径。
- **iOS**：通过 **Apple Shortcuts（快捷指令）** / Share Extension 充当轻量主动投递口。
- **零耗电物理场景标签**：用本地映射后的 Wi-Fi / 蓝牙设备名称（脱敏映射为 `Home` / `Office` / `Commute`）为并行时间窗打环境上下文标签，省去全天开启 GPS。

---

## 五、 早期推荐总体参考蓝图（`hub` 演变前身）

```mermaid
flowchart LR
    subgraph Collectors["多端采集层 (Edge Collectors)"]
        A["录音硬件 (VAD + ASR + 声纹)"]
        B["桌面 Daemon (剪贴板 + 前台窗口 + 隐私脱敏)"]
        C["浏览器扩展 (Dwell Time + Defuddle 正文)"]
        D["手机/生活源 (Android 通知 / iOS 快捷指令)"]
    end

    subgraph Hub["本地 Context Hub (Local-First)"]
        E["Ingest API & 标准 Event Schema"]
        F["双层存储: Raw SQLite/FTS5 + 分层 Markdown"]
        G["跨模态缝合引擎 (时间窗对齐 + 语义聚类 -> Episode)"]
        H["缺口检测与主动补全 (Gap Detector & STALE 状态演化)"]
    end

    subgraph Consumers["消费出口 (Agent Ecosystem)"]
        I["MCP Server (Tools & Resources)"]
        J["Claude / Cursor / OpenClaw / 自研 Agent"]
    end

    A --> E
    B --> E
    C --> E
    D --> E
    E --> F
    F --> G
    G --> H
    H --> I
    I --> J
```

> 进一步演进后的最新五层协议（`L0 → L4`）、六类整合策略横评以及 MCP Resource/Tool 具体定义，请移步阅读 [**整合方法与架构研究 (integration-methods.md)**](integration-methods.md) 与 [**RFC-0001**](../rfc/0001-context-integration.md)。

---

## 六、 研究与开源破局策略总结

1. **做“开放协议与通用底座”，不做封闭 App 壳子**：把统一 `Event Schema` 独立为规范文档，欢迎社区为各类平台和软件编写轻量 Collector 插件。
2. **隐私透明可见是开源生命线**：提供直观可查的“本地审计视图 + 敏感拦截过滤规则集”，让技术用户放心长挂后台运行。
3. **建立可量化验证的小闭环 Benchmark**：用脱敏多模态剧本直接实测 `无上下文 vs 纯流水日志 vs 注意力权重 + Episode 缝合` 的任务一次通过率，形成最有说服力的工程实证。
