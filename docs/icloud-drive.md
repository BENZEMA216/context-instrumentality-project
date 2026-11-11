# iCloud Drive 文件同步

## 手机使用与授权

1. 在 iPhone「同步 → 保存到 → iCloud Drive」中选择文件夹。必须由系统文件选择器进入 iCloud Drive；选择目录只保存本机访问记录，不写入录音。
2. 单独选择「仅授权后新录制」或「已有录音与以后收到」。前者排除授权前的已知片段及后来补到的旧录音；后者持续补入手机已持久接收的旧、新录音。未收到的手表清单不会冒充可导出的源文件。
3. 授权后增量保存。新增录音、已有转写补回、前台机会及手机实际获得的收件／BGProcessing 后台时间会继续队列；后台每轮最多两份录音任务，调用最多十八秒，到期保留进度。显式暂停保持暂停。已交给 iCloud 的文件由系统继续传输，不承诺 App 被挂起时仍持续生成导出。
4. 断开后停止后续写入，云盘文件和原授权范围保留；系统可能继续上传已经写入的文件。重选原目录后需明确继续。不同目录不会静默继承原授权。

目录使用 security-scoped bookmark 保存，使用期间配对获取／释放权限。每次解析都检查失效状态、真实 iCloud 属性、目录身份及原录音库标记；权限失效、目录替换、标记丢失或冲突时拒绝继续。首次导出前中断、尚无任何提交时，仅可在同一目录身份下恢复。未知的 provider 身份类型保守拒绝，不能用目录路径猜测身份。

系统目录选择与协调访问依据 Apple 的 [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)。此路径使用用户选择的目录；不等同于 App 自有 ubiquity container 或 CloudKit 数据库。

## 增量文件与状态

在所选父目录下建立独立的 `RecordForAgent-<library UUID>` 子目录：

```text
library.json
audio/<segment UUID>/<audio SHA256>.caf
manifests/<segment UUID>/<manifest SHA256>.json
transcripts/<segment UUID>/<transcript SHA256>.json
transcripts/<segment UUID>/<text SHA256>.txt
commits/<segment UUID>/<artifact-set SHA256>.json
```

录音 ID、原音频摘要与时间保持来源绑定。历史音频沿用 UUID／摘要路径。新分组音频按组建目录，文件名带录制时间、组内序号和片段 UUID。读取器以清单和提交记录核对路径。清单去除位置；转写 JSON 保持原结构，TXT 为正文加换行。只有用户已有的合法转写进入队列。

文件不可覆盖，暂存完成、流式核对源 SHA／字节数及文件身份后原子落盘，最后写 commit。迟到或新版转写产生新文件与提交，复用已有音频。已观察过的目标文件只有设备／inode／大小／纳秒 mtime 与 ctime 完全相同时才复用历史哈希；身份变化则重新核对，冲突不覆盖。这是本机增量证据，不声称每轮重新读取了全部音频。

界面区分「已写入目录」与「iCloud 已确认上传／待确认」。上传检查包括资料库标记、全部已提交报告及其引用的文件，不能只用文字上传状态表示整库已上传。上传计数只来自文件 provider 的 `ubiquitousItemIsUploaded` 等元数据，未知状态保持待确认；不在 `NSFileCoordinator` accessor 内等待云上传。Apple 对 [ubiquitousItemIsUploadedKey](https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemisuploadedkey) 的定义是该项已上传到 iCloud，不能据此声称 Mac 已下载或 Agent 已处理。

## Mac 只读入口

`AgentBridge/icloud_drive_library.py` 和 `scripts/read-icloud-drive-library.py` 只接受用户明确选定的资料库子目录。不会扫描用户整个 iCloud Drive，不自动配置任何 Agent，不下载 CAF，不改录音数据库，也不生成接收 ACK。

```sh
python3 -B scripts/read-icloud-drive-library.py \
  --library-root '/用户明确选择的路径/RecordForAgent-资料库UUID' list

python3 -B scripts/read-icloud-drive-library.py \
  --library-root '/用户明确选择的路径/RecordForAgent-资料库UUID' \
  read-transcript '片段UUID' --format text
```

程序校验库标记、commit、清单及转写引用的完整摘要与字节数，拒绝符号链接、越界路径、损坏和未完成提交。Mac dataless／尚未下载或有冲突的文字文件报告 pending；在内容读取期间禁止隐式 materialization，避免检查后驱逐的竞态触发下载。音频仅检查本机文件元数据，绝不打开 CAF；音频未在 Mac 下载不妨碍读取完整且已在本机的转写。

目录中出现的提交只代表当前可见资料。输出固定为 `sourceCatalogComplete=false`、`completeness=not_established`；不能将本机数量当作整段会话或完整一天。
