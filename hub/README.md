# Context Hub

Context Hub 将录音、剪贴板和其他来源的原始记录存进一个个人数据库，定期生成带出处的 Memory。用户在浏览器里管理两层数据，Codex 等 MCP 客户端通过同一个服务读取和修正记录。数据库可以放在自己的电脑或一台云主机。

![Context Hub 管理页，显示由合成资料生成的记忆和证据](docs/context-hub.png)

## 在这台电脑上试用

需要 Python 3.10 或更高版本，以下命令从仓库根目录执行。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install '.[agent]'
.venv/bin/context-hub serve
```

服务默认监听 `127.0.0.1:8741`，启动时和之后每隔 60 秒处理新增或变更的记录。保持这个终端运行，在另一个终端打开有管理权限的页面。

```sh
.venv/bin/context-hub open
```

第一次打开时资料库为空。可以从「原始记录」手工新建，也可以导入仓库自带的合成会议记录。

```sh
export HUB_OWNER_TOKEN="$(.venv/bin/context-hub token owner)"
.venv/bin/context-hub-import context-event hub/examples/recorder-decision.json
unset HUB_OWNER_TOKEN
```

在页面点击提取按钮或等待下次提取。「记忆」中会出现银杏收音笔的首版决定。点开「来源记录」中的条目可以看到原句、时间与来源定位。正确答案是第一版加入日期筛选，客户分组留到第二版。修改原文后，旧证据立即失效，再运行提取即可查看新结果。

## 接入 Codex 或其他 Agent

在仓库根目录执行以下命令，将这个 Hub 注册为 Codex 的 stdio MCP 服务，然后打开一个新会话。本机桥接进程会读取本机的 Agent 凭据。其他支持 MCP 的客户端也可把同一个可执行文件配置为 command，参数填 `mcp`。

```sh
codex mcp add context_hub -- "$PWD/.venv/bin/context-hub" mcp
```

可以用上面的合成数据连续问两件事，观察工具调用。

| 问法 | 预期读取 |
| --- | --- |
| 银杏收音笔第一版定了什么？ | `search_memory`。结果正文足以回答，保留证据 ID |
| 给我校正标签那句逐字原文和出处。 | 从 Memory 的 `evidence_ids` 选取证据，用 `get_raw` 查原文和定位符 |

MCP 提供十个工具。Raw 和 Memory 各有搜索、按 ID 读取、新建、修改与删除。服务说明引导 Agent 在缺失、矛盾、需要精确引文或用户要求核验时才读 Raw。标题、正文和来源定位符都按外部数据处理。Agent 写入同样需要相应记录的访问权限，更改或删除时还须带上读到的版本号。

## 导入自己的来源

导入器只读取明确选择的文件。复用上例的 `HUB_OWNER_TOKEN` 环境设置。下表中的路径均需替换为自己的导出路径。

| 来源 | 导入命令 | Hub 保存的内容 |
| --- | --- | --- |
| ClipContext | `context-hub-import clipcontext /path/to/clipboard.json` 或选 `Raw/manifest.json` | 单项文本、可用应用与设备上下文、来源身份和二进制表示的指纹。分块归档会校验清单 |
| Record for Agent | `context-hub-import record-for-agent /path/to/selected.zip` 或选 `export.json` | 录音段元数据、已有转写与分段、音频指纹。ZIP 可验证所附音频，独立清单只能验证元数据绑定 |
| 浏览器或其他来源 | `context-hub-import context-event /path/to/events.json` | 单个合法的 ContextEvent 或数组。支持 browser 等内建来源，以及 mail.message 等带命名空间的新来源 |

原生导出默认标为 `local_only`。如果要让 Agent 使用已选材料，先在本机界面审阅并更改可见范围，或在导入命令中明确加 `--privacy shareable`。通用 JSON 保留逐条标注。Hub 存储源文本与结构化字段，原始音频和剪贴板图片仍由生产端保存。导入是一次性快照，源应用内后续删除不会自动传播，Hub 的修改也不会写回源应用。相同内容重复导入会跳过，修改过的内容需要 `--update-existing`。浏览器目前可通过通用导入接入，扩展采集端属于后续工作。

## 存储、提取与人工修订

* 每条 Raw 保留时间、来源、生产者身份、权限和原始载荷。相同的来源、connector、source_id 标识同一条证据。
* 每条 Memory 含标题、正文、来源方式、版本和一组 Raw ID。第一版提取器从材料中选取至多三句，优先决策、时间和否定等线索，并保留已知说话人。缺少转写时只使用已有元数据。规则在本机或自托管服务执行，无需模型密钥。
* 同一权限等级下，完全一致且归属兼容的材料可共享一条 Memory 并保留多个出处。用户或 Agent 也可手工把多条证据编成一条结论。语义相似但措辞不同的记录目前需要人工判断。
* 修改 Raw 会立即移除失效证据。依赖该证据的人工结论会标为待复核并对 Agent 隐藏。删除 Raw 会移除受影响的人工结论；删除 Memory 保留 Raw，并阻止下一次提取把已删内容重新生成。两个写入者同时修改时，后提交者会收到 HTTP 409。
* 删除会清除本数据库的正文、搜索文本和失效的证据关系，保留防止重新导入的身份标记。源文件、数据库备份及已被客户端下载的副本有各自的生命周期。

记录格式与 HTTP 接口见[数据契约](../schema/memory.md)和[事件 Schema](../schema/context-event.schema.json)。

## 自托管在云上

下一组命令在云主机的仓库根目录执行。一个容器和一个挂载卷对应一个用户的资料库。暴露到公网的入口应在前面终止 HTTPS，也可以只通过 SSH 隧道访问回环端口。

```sh
docker build -f hub/Dockerfile -t context-hub:local .
docker volume create context-hub-data
docker run -d --name context-hub --restart unless-stopped \
  -p 127.0.0.1:8741:8741 -v context-hub-data:/var/lib/context-hub context-hub:local
```

容器首次启动会在卷中生成独立的 owner 和 agent 凭据。用可信终端上的 `docker exec context-hub context-hub token owner` 取回管理凭据，Agent 使用 `token agent`。不要把它们写进仓库、共享链接或聊天记录。在自己的电脑执行 `ssh -L 8742:127.0.0.1:8741 your-host`，打开 `http://127.0.0.1:8742/` 并在连接面板输入云端管理凭据。直连域名时请使用 HTTPS。

对远程 MCP 桥接进程设置 `HUB_URL` 和 `HUB_AGENT_TOKEN`。导入器使用相同 URL 及 `HUB_OWNER_TOKEN`。通过隧道时可额外设置 `HUB_MODE=cloud`。云模式只接收 `shareable` 和由来源方完成脱敏的 `redacted` 资料。本机和云主机各自保存数据，应用没有双向同步或多租户功能。

本机 macOS 默认目录为 `~/Library/Application Support/Context Hub`，Linux 默认 `$XDG_DATA_HOME/context-hub` 或 `~/.local/share/context-hub`。可以用 `HUB_DATA_DIR` 覆盖。SQLite 数据库、凭据和运行卷都应留在用户选择的存储位置，备份时使用 SQLite 在线备份或先停止进程。

## 开发验证

```sh
.venv/bin/python -m pip install '.[agent,test]'
.venv/bin/python -m pytest tests -q
```

GitHub Actions 在 Linux 上运行测试、验证安装包可独立加载资源，并新建云模式容器，写入合成证据，更换容器后用 Agent 凭据从原卷读回 Memory。[验收记录](VERIFICATION.md)列出了实际操作与观察结果。

## 本地 Agent 对话历史

`context-hub-history` 将选定的会话文件写入指定的本地 Hub SQLite 库。每条可见的用户或助手消息成为一条仅本机可见的 `ai_chat/chat_turn` Raw。提取器生成带角色的摘录 Memory，每条保留独立证据。来源定位包含供应商、会话和原生消息键，缺少旧版原生键时使用该日志的行号。相同的「好」在两个对话中会保留为两条证据。

| `--source` | 输入与覆盖范围 |
| --- | --- |
| `codex` | Codex rollout JSONL 或 JSONL.zst。支持完成事件与旧版用户、助手消息。对有明确线程 ID 的行检查归属，并区分用户、自动化和子 Agent 来源。读取 zstd 文件时需要本地 `zstd`。 |
| `claude` | Claude Code 单个会话 JSONL。提取两种角色的文本块，忽略思维、工具结果和运行元数据。子 Agent 保留独立会话标识。 |
| `gemini` | Gemini CLI 的会话 JSON，读取 `messages` 中的用户和 Gemini 文本，可按记录中的 projectHash 分组。 |
| `chatgpt` | 用户导出的 `conversations.json`，保留不同回答分支和 `reply_to`。隐藏节点、工具调用及附件数据跳过。 |
| `transcript` | 用户持有的其他 Agent 导出，形如 `{"provider":"example","session_id":"demo","project":"example-project","messages":[{"id":"m1","role":"user","timestamp":"2026-01-01T12:00:00Z","text":"首版改为绿色。"}]}`。每个文件一个会话。可选 `origin` 值为 `user`、`subagent`、`automation`、`unknown`，可选 `parent_id` 记录分支。 |

以下例子在专用库中运行。用安装好的命令或等价的 `python -m hub.history`。确认多个来源属于同一项目时，使用相同的 `--project`。未指定时，连接器依来源记录中的工作目录指纹、项目标识或独立会话分组。

```sh
context-hub-history import --database ./history.sqlite3 --source codex --files-from ./selected-rollouts.txt --defer-memory
context-hub-history import --database ./history.sqlite3 --source chatgpt --project example-project ./conversations.json --defer-memory
context-hub-history extract --database ./history.sqlite3
context-hub-history sessions --database ./history.sqlite3 --project example-project
context-hub-history digest --database ./history.sqlite3 --project example-project --limit 5
```

文件清单每行一个路径，`--files-from -` 从标准输入读。每个文件在独立事务内导入，确认完整后提交。默认遇到错误停止，`--keep-going` 可继续处理其余文件，并在汇总中报告拒绝数及非零退出状态。相同消息重导不新增。记录改变时，先检查后用 `--update-existing` 修订；旧版可通过 `versions --raw RAW_ID` 在本地查看。删除 Raw 会清除该消息所有保留版本，并阻止后续重导恢复。文件里缺少一条旧消息不会自动表示用户要求删除。

`sessions` 返回项目、来源、会话键和记录数。`brief --session EPISODE --limit 30 --offset 0` 按时间返回带角色、父节点、Memory 与 Raw 定位的记录。`digest` 可以按项目或会话生成有限篇幅的本地概览，将用户提及的更改、用户请求、助手自报进展和其他消息分别列出，附原始证据。分类来自原文关键词，助手自报的结果仍需独立验证。跨会话的决定批准、互斥分支裁决和双时间轴还在 [工作项 #5](https://github.com/BENZEMA216/context-instrumentality-project/issues/5) 中。默认权限下，Agent 的 `search_memory` 和 `get_raw` 无法读取私有原文。向外分享某项摘录，应单独选择相应材料和授权范围。
