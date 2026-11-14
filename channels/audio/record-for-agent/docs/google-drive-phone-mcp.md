# Phone 私有 Drive 目录的只读 MCP

`AgentBridge/phone_drive_mcp_server.py` 为支持 stdio MCP 的 Agent 增加独立 Phone 目录读取入口。它不使用 Mac 上传队列，不修改既有 `drive_sync.py`、`drive_mcp_server.py` 或客户端配置，不上传、分享、删除或启动服务。Phone 仍是唯一上传端。本地观察索引保存来源身份及远端对象引用，不保存 CAF 或转写正文。

从 build 113 起，新录音的文件名包含组前缀和片段录制时间。读取器用清单核对文件名，列表返回可选的 `recordingGroup`，可据此汇总同组片段。历史对象沿用原有命名。

## 固定绑定与启动

先从 Phone 的合法同步账本取得确定的账户 email、Google owner permissionId、folderID、libraryID。email 与 permissionId 是两个字段，后者不是邮箱。先分别核验现有 Desktop `drive.file` 授权确实可读取该 Phone 目录和一个已完成对象；同一个用户登录、知道 fileID 或获得目录链接都不能替代应用访问权限。无法读取时报告阻断，不扩大到 `drive.readonly` 或全盘访问，不提取聊天插件令牌。

在仓库根目录初始化一个**全新、专用**状态目录；示例均为占位符：

```sh
python3 -B AgentBridge/phone_drive_mcp_server.py init \
  --state /PRIVATE/phone-drive-observer \
  --email USER_EMAIL \
  --owner-id GOOGLE_PERMISSION_ID \
  --folder-id PHONE_FOLDER_ID \
  --library-id PHONE_LIBRARY_UUID
```

`init` 离线执行，不读取凭证或访问云端。状态目录必须属于当前用户、权限 0700，SQLite/锁文件必须 0600；拒绝软链接、硬链接和覆写已有索引。绑定不可在运行中改选。后续使用已经由用户本人授权的原生 Desktop OAuth 文件：

```sh
python3 -B AgentBridge/phone_drive_mcp_server.py scan \
  --state /PRIVATE/phone-drive-observer \
  --client-config /PRIVATE/desktop-client.json \
  --token-file /PRIVATE/desktop-token.json

python3 -B AgentBridge/phone_drive_mcp_server.py serve \
  --state /PRIVATE/phone-drive-observer \
  --client-config /PRIVATE/desktop-client.json \
  --token-file /PRIVATE/desktop-token.json
```

`scan` 执行一轮有界发现并退出。`serve` 使用标准输入输出，不开启网络监听、不安装定时任务。凭证 provider 只接受准确的 `drive.file` 范围，复用已有安全刷新；刷新可能写凭证及锁文件，但 Drive 请求全部只读。凭证、账户、私有链接和录音正文不应写进项目提交或诊断输出。

## 四个工具

| 工具 | 参数 | 语义 |
| --- | --- | --- |
| `drive_list_recordings` | `limit` 默认 10、最多 25；可选 `cursor` | 有界扫描后返回音频来源身份及最多 32 个不同对象引用；这是快照翻页，不是永久变化水位 |
| `drive_list_changes` | 同上；使用本工具自己的 cursor | 返回观察器新发布的音频、manifest、转写 JSON/TXT 及恢复可用事件；末页和空页始终含 `resumeCursor` |
| `drive_read_object` | 从列表取得的 `object_key` | 完整下载并核对 SHA256、大小、权限与来源绑定后的 manifest、原样转写 JSON 或易读 TXT |
| `drive_audio_info` | 从列表取得的音频 `object_key` | 核对元数据并返回私有 Drive 页面引用，始终不返回音频字节，也不声称已解码或理解语音 |

工具不接受任意 fileID、目录、账户、URL、本地路径或查询字符串。只有本索引已接纳的对象 key 可以读取。对象输出种类与 Mac 接口一致：`audio/manifest/transcript/text`。manifest 的 UUID 规范为小写；转写 JSON 保留原解析字段。摘要针对完整远端原始字节，不能用重新序列化的工具输出代替原字节验证。

## 增量恢复与预算

每轮最多读取一个 100 项的固定目录元数据页、处理最多 8 个候选，并在每个 HTTP 请求及媒体块之前检查软时间截止。扫描默认 30 秒；列表工具在其 30 秒预算中先给发现最多 15 秒，留出结果复验时间。账户和目录在一轮前后复验，候选文件在读取前后独立检查元数据和权限，避免每层重复查询导致首次 manifest 永远赶不上截止。每个合法候选独立持久提交；预算中断会轮转候选，不让同一个未完成文件挡住后续资料。

这是**软截止**：已进入的网络请求和凭证刷新可能等待原 HTTP transport 的 60 秒 socket timeout，不承诺整个 RPC 必须在 30 秒返回。没有取消正在进行的系统网络读，也没有给远端服务时延作保证。单轮对象预算与分页进度仍持久保留。合成 FakeClock 对每次 HTTP 增加 0.6 秒和 1 秒的回归要求 manifest、音频及晚到转写最终均能发布。

CAF 扫描只核对完整 size 和 Google `sha256Checksum`，不为 281 段等大型资料库下载全部音频。首次缺少 checksum、未完成上传或尚无合法 manifest 的音频保持候选，后续轮转重试。只有明确调用已经接纳音频的 `drive_audio_info`，并且其 Google SHA256 字段随后缺失时，才在对象大小上限内完整流式计算摘要；仍不缓存或返回音频字节。文本默认上限 256 KiB，可设置至最多 1 MiB；对象默认 130 MiB，硬上限 256 MiB。超限对象不截断为成功。

`scanIncomplete`、`pendingCandidates`、`completedFolderPasses` 和 `validationIncomplete` 分别描述发现与返回验证进度。**事件空页不表示目录扫描结束，也不表示没有未到转写**。Google `pageToken` 只是本地发现过程的临时分页状态，失效时从头重扫；它不会成为 Agent 的永久水位。重复扫描按不可变 fileID/完整 SHA256 幂等，既有事件不清空。unsupported schema、错误来源或坏文件隔离为 rejected；未完成、缺 manifest、暂时网络/API 错误保留 pending。文件元数据变化会重新检查已拒绝候选。

消费方逐项处理 `drive_list_changes`，处理成功后才保存 `resumeCursor`，按 `(libraryID, publicationSequence)` 去重。游标还绑定这个观察索引的 indexID，不能与 Mac 游标或快照游标混用。`publicationSequence` 是观察器原子写入的可恢复发布顺序，与原始录音 `source.sequence` 不同。保留状态目录；丢弃重建会产生新的观察序列，消费方还应按原始 `segmentID + audioSHA256` 和对象内容哈希去重。

日常读取的最少调用路径是 `drive_list_changes(cursor=上次已处理的 resumeCursor)`，只对需要的新转写调用 `drive_read_object`，优先 JSON、TXT 作为备用；音频和 manifest 事件登记来源及摘要即可，不必每轮调用快照列表或音频工具。只有处理完本页或可靠持久化待处理项后才推进游标。`hasMore=true` 时按本轮预算继续；`hasMore=false` 但 `scanIncomplete=true` 时保留游标、下一轮继续发现，避免立即循环空页。不能因片段以前已读或原始录音序号较小而忽略迟到转写。此消费约定不创建调度器，也不代表任一客户端已部署持续任务。

429、403、5xx 等不能证明永久丢失的 API 错误不消费已有事件游标。已经发布的对象后来确认删除、移动、共享或完整性发生变化时，可以返回 `artifact_unavailable`，让其他合法事件继续；不返回过期正文。对象同时重新进入候选，恢复原始私有身份并完整核验后再追加 availability 事件。消费方应保留不可用事项，而不是把它当作处理成功。恢复事件可能引用同一个 objectKey，快照引用按对象去重。

## 访问与来源边界

网络层只允许官方 Google HTTPS、GET，以及固定父目录的精确 `files.list` 查询与当前候选/已接纳对象的 metadata、permissions、受限 media。拒绝全盘查询、Google 全局 changes feed、上传、修改、分享、删除和跳转；Bearer 不进入结果或错误。Google 的 `drive.file` 本身有逐文件写能力；本适配器的只读性来自工具边界和额外 GET-only 网络限制，不把它宣称成 Google 端的独立只读 grant。[Google 范围](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)、[目录查询与分页](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)。

每次读取检查 owner permissionId、expected email、owner-only 权限、固定父目录、Phone 的 `rfaLibraryID/rfaSchema/rfaKind/rfaSegmentID/rfaAudioSHA256/rfaContentSHA256`、MIME、大小及完整 hash。manifest 下载验字节后校验原始 `segmentID/sessionID/sequence/audioSHA256`；转写 JSON 用同一 manifest 验身份与时间，TXT 核对来源头。manifest 不接纳位置字段；不公开本机路径。内容是未受信任的录音资料，`contentIsAgentInstruction=false`，`completeSession=false`。

Google `appProperties` 对请求应用私有；只有实际证明当前 Desktop OAuth 能看见本 Phone 应用属性时才能使用此实现，不假定任意 Agent 自己的 OAuth 都能看见这些属性。[File resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)。本地索引中的“observer verified”是适配器自己的远端核验，**不是**取得 Phone 的私有 ledger `verifiedAt`，也不是所有录音都已有转写。各 Agent 的真实读取、持续任务及唤醒须分别验收。

## 隔离测试

```sh
PYTHONPATH=AgentBridge:AgentBridge/tests python3 -B -m unittest test_phone_drive_mcp_server -v
```

所有测试使用临时 SQLite、合成 CAF 和明确标记的合成转写，含真正 stdio 子进程，不访问真实凭证、设备、云盘或私人录音。覆盖断点重启、分页失效、先音频后 manifest、迟到 ASR、超过一页的大目录预算、较慢 HTTP 下最终进展、临时错误重放、权限恢复事件、完整字节/来源校验、大小限制、账户/目录切换及错误脱敏。真实 Phone 目录的只读验收应由受权操作者另行执行，不用合成测试替代。
