# 微信聊天记录

这个渠道处理个人微信会话。历史记录可由用户选取的文件进行一次性导入。增量工具在 Mac 上定期识别一个前台会话的可见文字，写入本地 Context Hub，并可将当前会话导出成独立 JSON 文件。

微信客户端的“导入与导出”“迁移与备份”用于设备间迁移、备份和恢复。我们查到的公开资料没有给出个人账号定期导出逐条可读消息的受支持接口。工具使用已选文件或可见窗口，不解析微信备份。微信版本、系统菜单及可迁移内容会有差异。[华为的微信迁移与备份操作说明](https://consumer.huawei.com/cn/support/content/zh-cn01118496/) · [微信帮助中心 Windows/Mac 备份条目](https://cs.help.wechat.com/hc/en-us/articles/11917889397775-How-to-Backup-Restore-WeChat-Chat-History-on-Windows-Mac)

## Mac 上开始采集

需要 macOS 14 或更高版本、Python 3.10+ 和带 Swift 5.9+ 的 Xcode 命令行工具。从仓库根目录安装；已有本项目虚拟环境可复用。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install .
swift build --package-path channels/wechat/ocr -c release
```

1. 打开 Mac 微信，选一个具有唯一可见标题的聊天。第一次可以用只含测试文字的会话。双击 [start.command](start.command)，输入界面上完整的会话标题（含可见的群人数）、当前账号的本地别名和会话标识。如果还要导入 WeFlow 历史，标识填同一会话的 `session.accountId`。
2. 按 macOS 提示授权屏幕录制，再切回选好的微信窗口。听提示把鼠标依次停在标题文字左上、右下，以及消息区左上、右下。把联系人侧栏、聊天标题、输入框和草稿留在消息区外。四个点都无需点击。
3. 保持工具运行。默认每 15 秒观察一次，每 5 分钟更新一次该会话的 JSON 快照。切到其他 App 或会话时会跳过。回到终端按 **Ctrl-C** 停止，工具会再导出一次最新快照。进程意外退出后，已入库的观测可以用下方的 `export` 命令重新导出。

默认数据库位于 `~/Library/Application Support/Context Hub/local.sqlite3`。启动器把快照保存在同目录下的 `WeChat Exports/`，文件名含不透明的会话标识。文件为本机用户可读写的明文 JSON，存放位置可通过 CLI 选择。每次基于一致的数据库快照替换本会话文件；在 Hub 删除或修改的证据会反映到下次导出。手工复制到其他位置的文件有独立的生命周期。打开现有 [Hub 管理页](../../hub/README.md) 即可查看 Raw 和定期产生的 Memory。

## 一次性接入历史

**已有 WeFlow 原生 JSON。** 启动本机 Hub，用 owner 令牌导入。这里与采集命令的 `--account` 使用同一个本地别名。

```sh
export HUB_OWNER_TOKEN="$(.venv/bin/context-hub token owner)"
.venv/bin/context-hub-import weflow-json "/path/to/chat.json" --account personal
unset HUB_OWNER_TOKEN
```

支持包含 `weflow`、`session`、`messages` 的详细 JSON。每条消息保留时间、已知发送者、出处和可用的回复关系。普通文本、引用、媒体路径或转写保留各自的来源语义。附件不会被自动打开。文件上限 128 MiB，可以在导出端按会话、日期拆分。有平台消息 ID 时跨批次去重。缺 ID 时只能在同一文件内去重。重复导入会跳过已删除记录，冲突计数 `conflicts` 表示相同身份下已有不同内容，其他新消息仍会继续导入。人工确认后可用 `--update-existing` 替换冲突。一次导出缺行无法证明撤回。[WeFlow 原生导出字段](https://github.com/hicccc77/WeFlow/blob/91adcfdbb24e8e147d8332440b8c6ac899ad2abf/electron/services/export/formatters/JsonFormatter.ts#L320-L359)

**没有结构化导出。** 在微信中手工选取需要的历史文字，保存为 UTF-8 文本，按片段导入（每文件最多 2 MiB）。也可以在已校准的会话里手工翻到旧消息，停留至少一个采样周期。文本片段整体保存，OCR 只保存当时实际看见的文字，两者都不会推测发送时间或发言人。

```sh
.venv/bin/context-hub-wechat import-text "/path/to/selected-chat.txt" \
  --account personal --conversation project-room
```

## 命令行采集和导出

以下为与启动器相同的采集方式，示例中的账号、会话标识和标题均需替换。日志只打印状态、原因、记录 ID 或数量。命令行 `--title` 是显示名，本机有进程查看权限的软件可能看到该参数。

```sh
OCR="$PWD/channels/wechat/ocr/.build/release/wechat-ocr"
mkdir -p -m 700 "$HOME/Library/Application Support/Context Hub/WeChat"
layout="$HOME/Library/Application Support/Context Hub/WeChat/layout.json"
"$OCR" request-permission
"$OCR" calibrate > "$layout"

.venv/bin/context-hub-wechat watch --helper "$OCR" --calibration "$layout" \
  --account personal --conversation project-room --title '项目讨论' \
  --interval 15 --export-dir "$HOME/Library/Application Support/Context Hub/WeChat Exports" --export-every 300
```

`watch --once` 只处理一轮，输出 `created`、`unchanged`、`skipped` 或 `error`；技术失败以非零状态退出。单轮测试可先 `sleep 5` 再执行命令，给自己切回微信的时间。长时命令在下一轮重试暂时失败的操作。电脑睡眠或进程停止时会留下采样空档；默认不设置登录启动。

单独执行导出，会在指定目录原子更新 `wechat-<会话标识>.context.json`。内容是当前仍有效的 ContextEvent 数组，保留来源和原有隐私等级。结构化消息、手工片段和 OCR 各自有独立记录，即使文字相同也不会自动认成同一条消息。

```sh
.venv/bin/context-hub-wechat export --account personal --conversation project-room \
  --export-dir "$HOME/Library/Application Support/Context Hub/WeChat Exports"
```

## 识别边界与权限

- 屏幕权限由用户显式授予。工具用 ScreenCaptureKit 选择当前位于前台的微信进程和已校准的确切窗口，检查尺寸、显示器和登录状态。标题区和消息区裁自同一帧。仅在单行标题高置信完整匹配时才运行正文 OCR。Vision 在本机处理，截图不落盘。[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) · [Vision 文本识别](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- OCR 根据窗口和可见标题选取会话。账号别名和会话 ID 由用户指定。完全同名的聊天在同一窗口内无法靠标题分辨，请使用唯一显示名；无法区分时仅导入已选文件。切换微信账号、重开窗口、改变标题或调整侧栏、输入区、缩放和窗口尺寸后，请停止并重新校准。同尺寸下的内部布局变化需要用户判断。
- OCR 记录文字、行框、置信度和观察时间。只在相邻画面有可靠文字重叠时裁掉旧行。跳过采集或间隔超过 90 秒会打断连续性。同文气泡、瞬间出现又消失的消息、屏外消息、语音和附件原件无法可靠恢复；存量与增量覆盖率取决于窗口实际展示过什么。
- 三种入口默认使用 `local_only`，本地 Agent 看不到这些 Raw 及派生 Memory。用户可在 Hub 中分别审阅并授权。OCR 和手工片段的发送人标为未知；导出的账号或聊天名称本身也可能包含个人信息。

## 开发验证

```sh
.venv/bin/python -m pip install '.[test]'
.venv/bin/python -m pytest tests -q
swift test --package-path channels/wechat/ocr --scratch-path "$(mktemp -d)"
```

原生测试在内存中绘制有中英文、侧栏和草稿的合成窗口，使用生产 Vision 识别路径。Python 测试覆盖重叠导入、重复画面、采样中断、修改与删除、账号隔离、本地权限和周期导出的原子替换。
