# Persom 0.1.200 如何把上下文变成 Agent 能用的记忆

假设用户在 Codex 会话中说「确认把首版从私有云改成 iCloud」，几天后换到另一个 Agent，问「我们当初怎么定的，现在做完了吗？」这里有三个需要分别保真的对象：说过的原话、当时生效的决定，以及软件现在的状态。Persom 为这三者提供了不同的入口。

研究对象是北京时间 2026-11-21 发布的 macOS 正式版 0.1.200。核对了官方 ZIP 的 SHA-256（`7ad8ab9f66f61aee5929033f3d2cbff990644c0ae839744e6dc517cec66ae315`）、Electron 内随包交付的来源适配器、Python Runtime、Agent Skill 和历次发布说明。在临时目录实跑了正式包的独立会话导入模块；没有启动桌面采集或连接个人账户。另用独立的开源 Personal Model 提交 `b7a28ff` 验证了部分机制，下面标明适用版本。[正式发布](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.200) · [发行包元数据](https://api.github.com/repos/Intuition-Lab/persome-releases/releases/tags/v0.1.200) · [开源版本](https://github.com/Intuition-Lab/personal-model/tree/b7a28ffadaed3d83d9522efc8c171d6d642fd91b)

## 从哪里拿资料

| 入口 | 已核实的来源和读取边界 | 得到的材料 |
| --- | --- | --- |
| 桌面活动 | macOS 辅助功能读取界面，必要时用本机 OCR 补文字。0.1.200 点击 Orb 可聚焦飞书、微信、ChatGPT、Codex 正在显示的对话，排除侧栏预览与未发送草稿。这条规则专指 Orb 的当前对话功能。 | 带时间、应用和窗口的可见片段；某些模式可以留截图。被显示不等于被用户说出、同意或执行。 |
| Agent 历史 | 0.1.200 桌面导入器支持本地 Claude Code 和 Codex 的会话 JSONL。另一条路径可读 Claude Code、Codex、OpenClaw、Hermes、Pi 的指定长期记忆文件，具体目录按工具分别定义。 | 带角色的对话节选、项目/分支线索或源工具已有的记忆。公开材料不足以证明能拿到各家云端账户的完整历史。 |
| 文件与知识库 | 可选文件夹、Obsidian、Notion；另有拖入文件、扫描 PDF OCR。通用文件夹适配器可只建文件名、类型、位置的目录，对支持的文本格式补首段。 | 文件清单、文档文字、定位符或提取文本，正文覆盖度取决于入口和格式。 |
| 邮件、协作与日程 | Apple Mail、Calendar、Gmail、Slack、Linear。Slack 可选频道，Gmail 可限定回溯天数。Google/飞书文档出现在屏幕上也可触发任务。 | 源文档、邮件或消息片段、日历事件、工单及元数据。数据可进一步形成承诺、提醒或任务候选。 |
| 其他随包适配器 | `source-adapters.mjs` 还注册了 Apple Notes 和浏览器；可读所选笔记文件夹或 Chromium 系浏览器配置下的历史/书签。适配器存在与设置页是否向每个账户展示是不同证据。 | 选中范围内的笔记或浏览记录。访问历史本身不能证明读完了页面。 |
| 会议与主动补充 | 对已确认通话授权录音，形成会议笔记；Orb 笔记及用户向 Ask 明确发出的更新、删除要求也是输入。 | 音频/转录、带参与者的会议内容、用户本人确认的更正。0.1.191 发布说明称笔记完成后删除会议录音。 |

商业版核验位置为 `app.asar/src/main/source-adapters.mjs`、`source-connectors.mjs`、`memory-import.mjs`。这些模块列出的能力不代表用户已启用、已授权或已成功同步。可选云同步与推理服务各有自己的数据流；本机 OCR 不能推出全流程离线。[桌面会话与扫描文件](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.191) · [账户来源](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.188) · [选定范围与项目页](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.194) · [会议授权](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.199) · [云同步范围的发布说明](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.135)

## Raw 到底是什么

**一次屏幕观测。** 随包 Runtime 用 JSON 缓冲采集观察，并在 SQLite 的 `captures` 中维护可检索字段。下面字段来自 `store/fts.py`，值为合成示例，省略空字段。该行只能证明某时某窗口有这些可见字。仅凭窗口名无法推断某一句的作者。

```json
{"id":"capture-demo-01","timestamp":"2026-11-01T12:00:00Z","app_name":"Codex","window_title":"DemoVault","visible_text":"确认把首版改成 iCloud。"}
```

**一份连接器文档。** `store/source_documents.py` 按 `connection_id + external_id` 识别源对象。`source_documents` 存当前版本号、已应用版本、内容哈希、标题、定位符、检查时间与状态；`source_revisions` 用 `document_id + revision` 存各版正文、来源修改时间、本机观察时间和对应的记忆条目 ID。它投影为注明来源的参考资料。邮件里某个人提出建议时，这一层仍可保留「来源说了什么」的语义。

**一段外部 Agent 对话。** 对话在源头是 JSONL。0.1.200 的导入器挑选用户/助手可见文本，过滤工具输出、环境包装和部分噪声，把选取的内容编成含项目、角色和对话节选的 Markdown。最后一段助手回复在符合条件时单列为 Outcome。Runtime 收到的对象有 `source`、`kind`、`relative_path`、`content` 四个字段。同一会话后续补充时，导入后端会查找先前条目并处理版本替代。原始 JSONL、导入正文和展示的事件卡，是三种保真程度不同的东西。[0.1.200 正式包](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.200)

### 同一句决定，换一个位置会发生什么

用正式包原样交付的 `MemoryImportService.import(["codex"])` 处理 24 条交替的用户/助手消息。两个试验中会话长度、日期、项目及分支都相同，决定始终由用户说出。只改变这句决定所在的位置。接收端在 `/_memory-import` 写库之前截获提交对象；没有人工构造输出摘要，也没有使用模型。

| 唯一变化 | 源会话 | 导入正文保留的独立消息数 | 正文能否找到决定 |
| --- | ---: | ---: | --- |
| 决定在第 7 条 | 24 | 14 | 不能 |
| 决定在第 9 条 | 24 | 14 | 能 |

原因在导入器本身。筛选后超过 14 条时，保留头 2 条、尾 6 条，中间按间隔抽取最多 6 条；此外还有每条文本及输入大小上限。实验只验证此入口送交 Runtime 的正文，其他渠道可能独立捕获同一句话。这个结果没有衡量整套产品的召回率。以下命令在已下载的官方 ZIP 上可复现，测试器先校验将要加载的模块哈希，再使用临时合成目录。[复现实验](fixtures/persom-200-session.mjs)

```sh
unzip -p Persom-darwin-arm64-0.1.200.zip 'Persom.app/Contents/Resources/app.asar' > /tmp/persom-200-research.asar
node docs/research/fixtures/persom-200-session.mjs /tmp/persom-200-research.asar
```

## 中间产物怎样形成

桌面活动在随包 Runtime 的默认配置下大致经过以下阶段。配置可改；连接器文档和历史会话有直接导入路径，无须先模拟成屏幕观测。[正式包](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.200)

| 阶段 | 产物 | 这层解决的问题 |
| --- | --- | --- |
| 规范化 | 默认按一分钟整理的 timeline block，保存活动、文本、应用和时间窗口 | 连续屏幕可能重复同一段字。先收敛重复观测，保留后续能核对的文字。 |
| 工作段和候选 | 默认约五分钟增量处理已经闭合的窗口，按工作段生成事件记录。Memory Delta 提出实体、断言、关系与事件，并记录窗口、模型、被舍弃项和应用状态。 | 模型负责提出候选；写入代码检查来源、归属和其他条件。拿不到支持材料的高分候选也可能被舍弃。 |
| 事件记忆 | 桌面事件卡含 `id, title, content, summary, state, event_time, participants, segments, source_receipts, sources, evidence_revision, revision` 等；有明确所有者纠正时还可带纠正 ID。 | 把「某人讨论或做了什么」变成可查、可纠正的对象。进行中、已完成、未解决有不同含义，后续观察可以补充同一事件。 |
| 长期判断与视图 | 事件可被汇总进人、项目、承诺、每日简报。习惯判断另存陈述、置信度、状态与支撑观察；每份支撑可带记忆 ID、版本、观察日和引文。 | 一次选择可以成为项目事件。0.1.200 随包代码对习惯的自动提升另有门槛，例如至少三个不同的支撑日期、置信度至少 0.65；这些是规则参数，不能当作统计准确率或所有记忆的门槛。 |

**物理存储。** 随包配置中，长期条目的默认写入权威是 Markdown，SQLite 全文索引负责检索；可选的 EvoMem 模式能让版本节点成为权威，并为受它管理的条目重新生成可读 Markdown。日事件文件等有各自的写入路径。屏幕观测、来源版本、事件卡的支撑数据和习惯判断另有对应的表。项目页可以让人阅读当前状态，底层有足够结构时还可以重建该页。

核验位置为 `config.py`、`timeline/tick.py`、`writer/memory_delta.py`、`store/memory_deltas.py`、`model/memory_cards.py`、`store/graph_judgments.py`。另外还有可选的归档配置；不能认为每一项记忆都已逐字绑定到底层消息。事件卡、项目页、日报是同一份个人数据库的不同读法。[可展开的事件证据](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.89) · [习惯与异议](https://github.com/Intuition-Lab/persome-releases/releases/tag/v0.1.106)

开源版本的隔离实验又验证了两点。第一，给抽取阶段固定两个输出，带真实引文的事件候选置信度 0.90，带虚构引文的候选置信度 0.99，正式写入路径最终只保留前者。这个实验验证代码的证据筛选，真实模型抽取质量尚未测试。第二，将项目决定从「私有云」替代为「iCloud」后，默认搜索只返回新条目，显式包含历史则返回两条；按文件读取时，旧条目的 `superseded_by` 指向新版。这是一个能借鉴的「当前态与变更史」接口。[开源抽取测试](https://github.com/Intuition-Lab/personal-model/blob/b7a28ffadaed3d83d9522efc8c171d6d642fd91b/tests/test_memory_delta.py#L952-L972) · [开源读取实现](https://github.com/Intuition-Lab/personal-model/blob/b7a28ffadaed3d83d9522efc8c171d6d642fd91b/src/persome/mcp/server.py#L163-L271)

## Agent 怎样消费

0.1.200 随包 Skill 把依赖历史的问题路由到 MCP 的 `context(request)`。例如「我们说的那个功能上线了吗」，先用原问题找回讨论对象和过去的意图，然后查运行系统或代码确认当前结果。普通常识问题可以跳过记忆。[随包 Skill 与 MCP 实现](https://github.com/Intuition-Lab/persome-releases/releases/download/v0.1.200/Persom-darwin-arm64-0.1.200.zip)

- 一次返回含 `durable_memory`、`today`、`working_style`、`current_screen` 和 `source_guidance`。200 的 `mcp/server.py` 为长期候选取最多 5 条，每条正文最多 2,400 字符，并带 ID、路径、年龄、相关性排序、置信度与冲突标记等；当日近期活动最多 8 条。近期屏幕可以包含有限文本，因此 MCP 调用的资料范围值得独立设计。
- 需要精确证据时再调用专门工具。`read_receipt` 查某条记忆的回执，`resolve_evidence` 把直接来源与时间邻近材料分开，原件已过期时可返回缺失；`verify_fact` 提供新鲜度和冲突信号。相邻截图和低年龄数值都不能单独证明一项事实。
- 外部 stdio 的默认配置为只读。受信配置可以显式开放写工具，随包 Skill 还要求只有用户明确提出长期记住或纠正时才调用 `remember`、`correct_memory`。设置默认值和实际调用者能访问哪些来源是两件事。

## 我们取什么

1. **让机会式采集和完整历史采集并存。** 屏幕可以覆盖没有导出能力的应用。能得到原生消息的来源，保留用户授权的可见原文、消息 ID、作者、分支和版本；采样和裁剪留给投影层。为每条证据标明全文、节选、可见屏幕或已缺失。
2. **给项目结论一个身份。** 项目页以「项目 + 决策项」显示目前确认的值；提议、用户确认、技术实现和验收分别记录。变更显式指向旧决定，晚到的聊天可补历史。源文档更新、用户改主意、用户要求删除需要三种处理语义。
3. **给 Agent 一个短入口，再提供回查通道。** 先回答当前决定、有效范围、是否冲突、最近何时被证据支持。需要时回查特定消息。默认返回值遵循项目权限；屏幕全文、邮件原件及 Vault 高敏材料按各自范围读取。引用不能扩大权限。
4. **先衡量决定有没有丢。** 用同一份 Codex 会话和一份用户授权的云端导出，把同一句关键确认轮换放在开头、中间、结尾，再加入助手提议与另一个项目的同名决定。从全新 Agent 追问当前决定、变更原因及原句，分别检查答案、来源和权限。记录每种来源缺了什么，再决定下一批接哪些应用。[Context Hub 跨 Agent 设计议题](https://github.com/BENZEMA216/context-instrumentality-project/issues/5)

如果有机会问团队，我会保留三个问题。历史导入漏选一条确认后，产品在什么条件下能回源到原消息？两个项目或分支同时确认互斥决定时，怎样表现冲突、由谁裁决？删除或撤回某份资料授权后，哪些派生资料和哪些已连 Agent 的副本能同步撤回？现有公开材料和本次短实验都不足以完整回答这三点。
