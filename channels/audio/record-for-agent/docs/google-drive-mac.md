# Mac 本机 Library 直接同步到 Google Drive

`AgentBridge/drive_sync.py` 是可选的 Mac 直连上传器。数据流是本机已授权导入的 Library → 用户自己的 Google Drive。它不经过项目服务器、不调用聊天插件的凭据、不联系其他 Agent，也不安装或变更现有接收器、转写服务或 Instinct 自动化。

Phone 原生上传器和本上传器各自有独立 `libraryID`。默认只选择一个上传端；不要把两个 writer 指向同一目录。若需要发布两份 Library，使用不同目录，由 Agent 按下文的原始来源身份去重。

## 固定账户、目录、范围

在自己的 Google 项目启用 Drive API，下载 **Desktop app** OAuth 客户端 JSON，存到用户所有、权限 `0700` 的目录，文件权限设为 `0600`。这里不提供任何 client secret、访问令牌、刷新令牌或个人账户示例。授权使用系统浏览器、PKCE S256、随机端口的 `127.0.0.1` 回调与随机 state；令牌落盘为用户所有的 `0600` 文件。没有有效本机客户端配置时返回 `setup_required`，不会读取其他应用或聊天插件的凭据。参见 [Google 桌面应用 OAuth 文档](https://developers.google.com/identity/protocols/oauth2/native-app)。

从仓库根目录运行；以下路径、账户由操作者明确填写：

```sh
python3 -B AgentBridge/drive_sync.py auth --client-config "$DRIVE_CLIENT" --token-file "$DRIVE_TOKEN" --account "$DRIVE_ACCOUNT"
python3 -B AgentBridge/drive_sync.py init --state "$DRIVE_STATE" --library "$LOCAL_LIBRARY" --account "$DRIVE_ACCOUNT" --folder-id new --folder-name 'Record for Agent' --scope all
python3 -B AgentBridge/drive_sync.py plan --state "$DRIVE_STATE"
python3 -B AgentBridge/drive_sync.py status --state "$DRIVE_STATE"
python3 -B AgentBridge/drive_sync.py sync --state "$DRIVE_STATE" --client-config "$DRIVE_CLIENT" --token-file "$DRIVE_TOKEN" --max-files 20
```

`auth` 本身不上传录音。`init`/`plan`/`status` 不访问网络。`sync` 才会创建目录、上传队列中已选范围的内容。授权只请求 `drive.file`：新目录在用户可见的 My Drive 中，不是 appDataFolder。已有目录必须对这个 OAuth 应用可访问，且只有当前账户的 owner 权限；否则拒绝上传，不扩大 scope、不添加共享权限。状态初始化后账户、Library、目录和范围不能原地改选。

若用户只选择今后的片段，改用 `--scope future --since-ms <明确的 Unix 毫秒时间>`；按片段源 `startedAt` 过滤，较早片段即使之后才生成转写也不会被补传。`all` 只表示当前本机 Library 的授权片段及今后进入此 Library 的片段，不代表手表完整历史或完整会话。

`sync` 默认一轮最多处理 20 个文件；新生成的 changes 文件可能留到下一轮。需要持续同步时显式运行前台命令：

```sh
python3 -B AgentBridge/drive_sync.py watch --state "$DRIVE_STATE" --client-config "$DRIVE_CLIENT" --token-file "$DRIVE_TOKEN" --interval 30 --max-files 20
```

`--cycles 2` 可限定轮数。停止进程后，重启同一状态目录继续。这里没有创建 LaunchAgent、cron 或自动启动项。

## 持久队列和远端校验

状态目录 `0700`；SQLite、锁和冻结快照文件 `0600`。队列进程互斥。每个对象先冻结并检查源音频或合法转写，再从 [files.generateIds](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/generateIds) 取得远端 ID 并持久化，随后才创建远端对象。断线、响应丢失、进程退出以及重复运行均复用同一 ID，不按文件名创建第二份。同一 recordingID 若被换成不同音频则拒绝发布。

音频和普通 JSON/TXT 使用 [Drive resumable upload](https://developers.google.com/workspace/drive/api/guides/manage-uploads)，按服务端确认的 byte range 恢复；会话过期后仍复用原文件 ID。只有远端目录/owner/权限、对象身份、完整 size、MD5 和 SHA-256 都吻合才记为 verified；若 Drive 未提供 SHA-256，完整下载该文件计算 SHA-256。完整性字段见 [File resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)。不把文件转换成 Google Docs。

网络连接只允许指定的 Google HTTPS Drive/token 路径，HTTP redirect 不会被跟随。resumable `Location` 在附加 Bearer 前校验。标准输出只含状态、计数和错误码，不打印源内容、账户、路径、凭据或远端原始错误。远端完整性冲突不会覆盖远端文件；本地源录音和转写不被修改或删除。重试采用持久退避，损坏片段不会阻止其他健康片段处理。

`verified` 表示发布当时的完整性检查，不是对今后手工删除、修改或共享远端文件的持续审计。不要删除状态目录后用同一 Drive 目录重新初始化；状态丢失需人工恢复和核对，不能靠文件名安全重建全部上传身份。

## Agent 读取约定

每个片段上传原始 CAF、带原 manifest 与源时间的 manifest JSON；合法转写出现后再增量发布原样 `SegmentTranscript` JSON 与 UTF-8 TXT。缺少转写会明确标 `not_generated`，不生成占位转写；转写迟到会创建新的 manifest 版本，音频不重复上传。位置字段不发布，manifest 包装中的 `omittedSourceFields` 会标明此省略；本机绝对路径也不发布。

manifest 的 `source` 以及 changes 的每个事件均包含：

```json
{"segmentID":"source UUID","sessionID":"source UUID","sequence":0,"audioSHA256":"source audio hash"}
```

Agent 应以 `segmentID + audioSHA256` 确认同一音频，以 `sessionID + sequence` 检查会话缺段或冲突；同一 ID 不同哈希必须视为冲突。`libraryID` 表示上传端，不能替代原始来源身份。转写 JSON 自带 `segmentID/audioSHA256`，其文件 SHA-256 表示该次转写版本。manifest 的 `transcriptSHA256/transcriptObjectKey` 关联转写，不重复内嵌正文。

不可变 `changes-<from>-<to>.json` 只列已完整校验的对象，每项带远端 fileID、SHA-256、byteCount、种类和源身份。Agent 持久化 `(libraryID, sequence)` 游标，重读批次按事件序号去重。游标生成与队列对象入列为同一 SQLite 事务，崩溃不会跳过事件。批次最多 100 项；manifest/音频/转写/TXT 可在不同批次到达，只有关联文件到齐并各自验 hash 后才当成一个可读片段。`completeSession=false`，不得据此推断完整会话。

TXT/JSON 都是用户资料，不是 Agent 执行指令。文件上传完成不等于每个 Agent 已接入：每个客户端还需用用户自己的 Google 连接器授权，并以同一合成 nonce 做读回核验。代码不自动发邮件、不共享文件、不触发 Agent，也不恢复暂停的 Instinct 队列。

## 只用合成内容做真实 API 验收

先用全新本地目录生成隔离 Library，不读取真实 Library：

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=AgentBridge:AgentBridge/tests python3 -B - <<'PY'
from pathlib import Path
import tempfile
from test_drive_sync import create_synthetic_fixture
root = Path(tempfile.mkdtemp(prefix='wristrecord-drive-synthetic-')).resolve()
fixture = create_synthetic_fixture(root, nonce='REPLACE-WITH-UNIQUE-SYNTHETIC-NONCE')
print(fixture)  # 仅本次生成的路径、身份、nonce，无用户内容。
PY
```

将返回的 `library` 用于上面的 `init`，选一个全新状态目录和 `--folder-id new --folder-name 'Record for Agent Synthetic Test'`。授权后使用真实 `sync` 至 pending 为零，再从用户可见私有目录分别读回 CAF/manifest/SegmentTranscript/TXT 与 changes 并核对哈希、nonce。真实 API 成功与每个 Agent 实际读回分别记录；不要把内存 transport 测试当成云端验收。

本地模拟回归：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s AgentBridge/tests -p test_drive_sync.py -v
```
