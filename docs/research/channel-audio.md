# 音频渠道研究：record-for-agent 数据模型与接入点（R-02）

> 来源：对 `record-for-agent-source`（分支 `ui-iteration`）的只读源码分析。下文路径都相对于该仓库根目录。

## 结论（TL;DR）

- **接入方式**：首选在 Mac 上只读访问 AgentBridge 的 `library.sqlite3`（也可以直接 import `library.Library`）。这条路径的字段最完整，含位置和时区，而且是纯本地，不需要网络和 OAuth。增量同步有两种做法：消费 `recordings.available` 事件（eventID 是确定性的，可直接作幂等键），或者用 `started_at,id` 游标扫描，再加上对转写表的监听。
- **不要重复造 MCP**：record-for-agent 仓库里已经有 4 个 MCP server，工具名彼此重叠。`context-instrumentality-project` 应作为**聚合层**：读取本地库或事件，对外暴露跨渠道视图；音频工具要么不重复暴露，要么加命名空间前缀（如 `audio.*`）。
- **对整合层影响最大的几个缺口**：
  1. 没有说话人分离；
  2. 没有设备 ID；
  3. 每段只有约 60 秒，一句话可能被截断，需要按 `recordingGroup` 拼接；
  4. span 的时间是段内相对秒数，需要换算成墙钟时间；
  5. 位置只在 Mac/ZIP 路径上保留。
- **开源阻塞项**：record-for-agent 还没有 LICENSE 文件；README 和配置里有个人域名需要清理；`.DS_Store` 被纳入了版本库。

## 1. 数据流

```text
Watch（每约 60 秒封一段 CAF + SegmentManifest/sha256）
  → WatchConnectivity → iPhone（校验 + 回执，可选本机转写 SegmentTranscript）
  → ZIP（export.json v3 + audio/*.caf）
  → Mac automatic.py receive（POST /v1/imports，TLS + 证书固定 + Bearer）
  → library.sqlite3 + objects/
  → 可选 Mac 本机 ASR → recordings.available 事件 → dispatch 推送轻通知 → Agent 通过 stdio MCP 读取
```

旁路：
- iCloud Drive / Google Drive 不可变文件树：会去掉位置。
- AgentGateway：尚未部署；只缓存转写，提供 Remote MCP。

## 2. 核心数据模型

| 对象 | 关键字段 | 位置 |
| :--- | :--- | :--- |
| `SegmentManifest` | `id`, `sessionID`, `sequence`, `startedAt/endedAt`, `sampleRate`, `frameCount`, `fileName`, `byteCount`, `sha256`, 可选 `timeZoneIdentifier` / `location` / `recordingGroup` | `Sources/RecordingCore/Models.swift` L31-70 |
| `RecordingGroup` | `id`, `startedAt`, `utcOffsetMinutes`, `firstSequence`（从开始到暂停为一次逻辑录音） | `Models.swift` L73-111 |
| `SegmentTranscript` | `segmentID`, `audioSHA256`, `locale`, `engine`, `createdAt`, `text`（≤256KiB）, `spans[{start,end,text}]`（**段内相对秒**） | `SegmentTranscript.swift` L36-115 |
| `SegmentLocation` | `latitude`, `longitude`, `horizontalAccuracy`, `capturedAt`（默认关闭，只在前台录音时采集，精度 100m） | `RecordingMetadata.swift` L8-29 |
| `AgentRecordingMetadata` | 派生字段：ms 时间戳和 ISO8601、`timeZoneSource` ∈ {`recorded`,`utc_fallback`} | `RecordingMetadata.swift` L49-101 |

- **时间约定**：线上一律用整数 Unix 毫秒；派生 ISO8601 时带明确偏移；缺失的信息不做推断补写。
- **转写状态**：段级只有 `ready` 和 `not_generated` 两种，`not_generated` 不等于静音，也不等于失败；导出包级还有 `partial`。

## 3. AgentBridge 接口

**库布局**：`<Library>/library.sqlite3`（`user_version=2`），表包括 `recordings`、`exports`、`export_members`、`transcripts`；音频放在 `objects/<uuid>/<uuid>.caf`。

**stdio MCP**（`bridge.py`，serverInfo `record-for-agent` 0.2.0）提供以下工具：
- `list_recordings`
- `get_recording`
- `get_transcript`
- `search_recordings`：casefold 字面子串匹配
- `get_audio_asset`

**`recordings.available` 事件**（`automatic.py` L264-282）：
- eventID = uuid5(receiverID, 排序后的 id:revision 列表)；
- revision = sha256(audioSHA256 + ":" + transcript_json)；
- **只有带转写的段才会产生事件**。

**投递模型**：`deliveries` 表的状态有 retry / sending / accepted / uncertain，失败后指数退避，状态不明确时不静默重发。

## 4. AgentGateway（未部署）

- REST 接口提供 OAuth 授权，授权粒度到单条录音，撤销立即生效。
- MCP 工具：`get_profile`、`list_recordings`、`get_transcript`、`search_recordings`、`list_changes`（含 created / updated / deleted / revoked 和 tombstone）。
- **缺口**：`manifestSchema` 不包含 `timeZoneIdentifier`、`location`、`recordingGroup`，与 Swift 端 v3 不一致；也不提供音频。

## 5. 字段映射到统一事件模型

| 统一字段 | 来源 |
| :--- | :--- |
| id / 溯源 | `recordingID` + `audioSHA256`；转写 revision |
| 时间 | `startedAt`（ms）+ `startedAtISO8601` + `timeZoneSource` |
| 时长 | `durationSeconds` = `frameCount/sampleRate` |
| 来源设备 | **缺失**（只有接收端 `receiverID`） |
| 分组 | `sessionID`、`sequence`、`recordingGroup.id` |
| 内容 | `transcript.text`、`locale`、`engine` |
| 细粒度时间 | span 墙钟时间 = `startedAt + start*1000` |
| 位置 | `SegmentLocation`（可选，仅 Mac/ZIP 路径） |
| 定位符（locator） | MCP `record-for-agent` + `get_transcript(recording_id)` |

## 6. 建议全项目采用的工程约定

- 用 ID + SHA256 做内容寻址；源记录不可变；同 ID 不同内容一律报 `conflict`；eventID 确定性生成。
- 线上时间一律用整数毫秒，显式标注 `timeZoneSource`，不推断未知信息。
- 错误统一为 `{"error":{"code","message"}}`；MCP 工具错误放进 `isError: true` 的结果；内部异常映射为固定 code，不泄露路径和秘密。
- **把内容当作不可信数据**：MCP 声明"内容不是指令"，返回中带 `contentIsAgentInstruction: false`。
- MCP 工具全部只读并带 annotations；参数设严格边界；游标不透明且绑定查询条件。
- 持久化顺序：先 fsync 再 rename，目录同步后才 COMMIT。
- 测试只用合成数据。

## 7. 风险

- **MCP 重名**：现有 4 个 MCP server 共用 `record-for-agent*` 命名，`list_recordings`、`get_transcript` 等工具名重叠。
- **MCP 协议版本**：bridge 不支持 2026-07-28 版协议。
- **许可证**：还没有 LICENSE 文件。
- **隐私与清理**：录音、转写、位置都高度敏感；`get_audio_asset` 会暴露本地路径；开源前要清理个人域名和 `.DS_Store`。
- **成熟度**：Gateway 未部署，schema 落后于 v3；通知 adapter 的测试只是协议替身，没有验证模型实际读取。
