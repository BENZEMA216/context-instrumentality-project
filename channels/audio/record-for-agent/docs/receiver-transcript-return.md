# 从已配对的 Mac 取回转写

`Watch → iPhone → 用户自有 Mac 本机 ASR → iPhone 转写库 → 用户自己的 Google Drive`

Mac 已保存的转写通过原来的固定证书 HTTPS 接收服务返回手机。手机仍是该手机 Google Drive 目录的唯一写入端；Mac 不取得 Google 令牌，不写入手机的 Drive 目录。这个查询不会读取音频、启动 ASR、创建任务或发送 Agent 消息。旧的 `POST /v1/imports` 及保存回执保持兼容。

## 授权和限制

`POST /v1/transcripts/query` 使用已有 `Authorization: Bearer …`，不接受浏览器 Origin、重定向或 Transfer-Encoding。必须恰好提供一个 Authorization、Content-Type 和 Content-Length。Content-Type 为 `application/json`，请求不超过 32 KiB，每批 1–4 项，交付 ID 和片段 ID 各自唯一。所有 GET 继续返回 405。

每项必须携带完整持久保存回执和精确来源。服务端先核验整批的接收器身份、回执全文、归档 SHA-256、同一 export 的全部成员及片段清单，全部通过后才查询任何转写正文。接收中的任务、失败任务、任意录音 ID、只存在于手动导入库的片段，以及最后一项无效的混合批次均不能返回正文。回执的 recordingIDs 顺序也需要相同；UUID 以语义比较，允许 Swift 的大写表示。时间为整数 Unix 毫秒，不能用近似日期扩大能力范围。

历史接收器没有单独登记 Phone 的 pairingID、grantEpoch 和 sourceInstallationID。因此此接口的服务端能力边界是**现有 bearer + 完整持久回执 + 对应 export 成员 + 精确来源**。scope 的 receiverID 由服务端核验；其余三个 UUID 只原样回显，供手机拒绝暂停、解除或更换授权后迟到的结果。它们不构成服务端独立的历史 Phone 授权证明。持有这份 bearer 和完整回执的人可能读取该回执范围内的结果；手机端暂停和解除会停止查询，不能远程撤销已经取得的副本。

手机现有自动归档把 exportID 设为 deliveryID，并且每次归档只含一段。一般导入接口仍允许不同 exportID；这种历史归档在本查询中拒绝，不能通过扩大成员集合来推断授权。

## JSON 契约

以下 UUID、哈希和时间均为合成示例，实际请求必须来自同一已配对接收端的已保存任务。对象不接受额外字段。

```json
{
  "schemaVersion": 1,
  "scope": {
    "receiverID": "00000000-0000-4000-8000-000000000001",
    "pairingID": "00000000-0000-4000-8000-000000000002",
    "grantEpoch": "00000000-0000-4000-8000-000000000003",
    "sourceInstallationID": "00000000-0000-4000-8000-000000000004"
  },
  "items": [{
    "receipt": {
      "schemaVersion": 1,
      "receiverID": "00000000-0000-4000-8000-000000000001",
      "deliveryID": "00000000-0000-4000-8000-000000000005",
      "archiveSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "recordingIDs": ["00000000-0000-4000-8000-000000000006"],
      "storedAt": 1792876029274
    },
    "source": {
      "segmentID": "00000000-0000-4000-8000-000000000006",
      "sessionID": "00000000-0000-4000-8000-000000000007",
      "sequence": 0,
      "audioSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }]
}
```

响应 `schemaVersion=1`，scope 原样回显，items 与请求同顺序，每项包含规范化的完整 receipt、source 和以下字段：

| 字段 | 内容 |
| --- | --- |
| status | `ready`、`pending`、`retry`、`no_speech` 或 `unavailable` |
| transcriptJSON | ready 时为已保存、已通过来源校验的 SegmentTranscript schema 1 JSON 字符串；其余为 null |
| transcriptSHA256 | 该字符串 UTF-8 原始字节的 SHA-256；其余为 null |
| transcriptByteCount | 同一字节串的大小；其余为 null |
| asrUpdatedAt | 可选，仅来源哈希一致的持久 ASR 状态更新时间，整数 Unix 毫秒 |
| reason | 可选；过大的正文为 `transcript_too_large` |

transcriptJSON 使用现有 `canonical_json`：键排序、紧凑分隔符、ASCII 转义、有限数字。SHA 和大小针对这个嵌套字符串解码后的 UTF-8 字节，不是外层响应字节。转写绑定 segmentID 和 audioSHA256，createdAt 为整数 Unix 毫秒，跨度时间为秒。实际已保存正文优先于旧的 no_speech 状态。

`pending` 表示没有已保存的 ASR 任务或任务在运行；`retry` 表示等待重试；`no_speech` 仅表示同一音频哈希的本机 ASR 返回无文字，不是整段没有语音的证明。三者都不能伪造空正文或标为转写完成。`unavailable` 表示结果缺失、损坏、来源不一致或超出限制。

响应最多 4 MiB，按最终 UTF-8 JSON（包括嵌套字符串转义及末尾换行）计数。单项超限返回 unavailable 和 transcript_too_large，不截断正文。仅元数据已超限或查询整体失败时返回 503。查询按只读 SQLite 快照执行，忙等待上限 2 秒，总查询期限 10 秒，检查调用取消；网络读取也有 10 秒超时。断连不会留下后台查询或 ASR 任务。

错误只有固定信息，不返回请求值、路径、SQL、ASR 错误或任何正文：401 未配对，400 JSON/契约错误，403 回执或来源核验失败，413 请求超限，503 暂不可用。手机遇到不支持此接口的旧服务或失败响应时应保留原录音和已有转写，按自己的有界重试策略稍后再取。

## 部署和回滚边界

接收服务使用 Python 3.9 标准库；receive 模式需要同一版本目录内的 `automatic.py`、`automatic_transcripts.py`、`automatic_transcription.py`、`bridge.py`、`library.py`。仅 dispatch 命令额外需要 `delivery_clients.py`。Apple 本机 ASR 可执行文件继续由已有 `--transcriber` 路径提供，不属于这次 Python 更新。

部署者应把这组代码和冻结摘要放进新的私有版本目录，保留旧代码，原样复用现有 receiver 身份、状态库、录音库、token、证书、私钥和 ASR helper。凭据及录音不复制进代码目录或仓库。本次没有数据库迁移，也不重建配对。

修改 LaunchAgent 前先保留原配置和原权限，停止旧实例后再启动新入口，避免两个服务占用同一端口或同时恢复导入。部署后分别检查旧 imports 兼容、匿名请求拒绝、新查询精确来源匹配和实际手机回流；合成测试通过不能代替这些生产验证。原运行服务和升级后的磁盘代码必须分开记录。

回滚时恢复旧 LaunchAgent 入口和 WorkingDirectory，继续使用原有状态及配对材料，随后核对 receiver 身份和旧导入路径。新接口只读、没有新增数据表，原转写和保存回执仍可被旧服务使用；手机查询遇到旧服务不支持时保留本地内容。部署、重启和真实数据验证由拥有该机器运行权限的部署者执行。

## 合成验证

```bash
PYTHONPATH=AgentBridge:AgentBridge/tests /usr/bin/python3 -B -m unittest test_automatic_transcripts test_automatic test_automatic_transcription -v
```

测试只创建临时合成录音、隔离数据库和 loopback TLS 服务，覆盖整批先授权再读正文、全部回执及来源字段、export 成员、状态区别、只读取消、最终字节上限，以及真实 HTTPS handler 的新旧路由。它不接触用户现有服务、录音、云盘或聊天。
