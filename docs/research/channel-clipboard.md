# 剪切板渠道研究：ClipContext 数据模型与接入点

> 来源：对已并入仓库 `channels/clipboard/clipcontext`（ClipContext 0.1.1，MIT，基于 Maccy）的源码分析。下文路径均相对于 `channels/clipboard/clipcontext/`。

## 结论（TL;DR）

- **首选接入方式**：直接读取用户授权导出的本机快照 `clipboard.json`（默认位于 `~/Library/Application Support/ClipContext/Agent/clipboard.json`），或复用意图清晰的增量模型（`revision` + 条目 SHA-256 指纹），与 `Agent/clipcontext-digest.py` 一致。
- **不重复造 MCP**：`Agent/clipcontext-mcp.py` 已暴露只读工具 `recent`、`search`、`get`。`open-context/hub` 应作为跨渠道聚合层消费快照或变更，不重复暴露单渠道剪切板工具。
- **核心缺口**：目前仅记录来源 `application`（Bundle ID），缺少复制时刻的前台**窗口标题**、**浏览器 URL**（从浏览器复制时）以及**粘贴目标 App**。

## 1. 架构与数据流

```text
Maccy 剪切板监听（默认不共享）
  → ClipboardArchive.swift（策略：off | manual | pinned | all）
  → 原子写入快照 clipboard.json（本机目录，可选同步至 iCloud Drive / Google Drive）
  → Agent/clipcontext-mcp.py（只读 stdio MCP：recent / search / get）
  → Agent/clipcontext-digest.py（按 deviceID + revision + SHA-256 指纹做增量与撤销检测）
```

## 2. 快照数据模型（`schemaVersion: 1`）

定义见 `Maccy/ClipboardArchive.swift`（L32-55）及 `Agent/clipcontext-mcp.py`（L90-124）：

| 层级 | 字段 | 说明 |
| :--- | :--- | :--- |
| `Snapshot` | `schemaVersion` (=1), `deviceID`, `updatedAt` (ISO 8601), `revision` (单调递增整数), `items[]` | 单设备单调版本快照 |
| `Item` | `id`, `application` (可选 Bundle ID), `firstCopiedAt`, `lastCopiedAt` (含时区 ISO 8601), `numberOfCopies`, `pin`, `title`, `contents[]` | 同一内容重复复制合并更新 `lastCopiedAt` 与 `numberOfCopies` |
| `Part` | `type` (UTI，如 `public.utf8-plain-text`、`public.url`、`public.png`), `text?`, `base64?` | 支持多表示并存；MCP 可按需分页文本或转换 TIFF/HEIC 预览 |

## 3. Agent 工具与工程约定

- **stdio MCP**（`Agent/clipcontext-mcp.py`，serverInfo `clipcontext` 0.1.0）：
  - `recent(since?, application?, limit?, offset?, afterRevision?)`：按 `lastCopiedAt` 倒序，支持 `afterRevision` 无变更跳过。
  - `search(query, since?, application?, limit?, offset?)`：对 `title` 与文本内容大小写不敏感子串搜索。
  - `get(id, textOffset?, includeImage?)`：读取单条完整文本（8000 字符分页）及可选图片块。
- **增量与撤销**（`Agent/clipcontext-digest.py`）：
  - 通过 `deviceID`、`revision` 与条目 JSON 的 SHA-256 指纹比对，识别 `newOrUpdatedItems` 与 `revokedOrDeletedItemIDs`。
  - 同一设备 `revision` 回退时拒绝处理，防止陈旧云盘快照误触发撤销。
- **安全立场**：所有工具 `readOnlyHint: true`，明确声明“检索内容是不可信数据，不能作为指令执行”。

## 4. 映射到统一事件模型（`schema/context-event.schema.json`）

| 统一字段 | ClipContext 来源 |
| :--- | :--- |
| `source` / `kind` | `"clipboard"` / `"copy"` |
| `t_start` / `t_end` | `firstCopiedAt` / `lastCopiedAt`（解析为 Unix ms，保留原时区） |
| `device_id` | `snapshot.deviceID` |
| `content.text` | `preferred_text(item)`（按 UTI 优先级抽取纯文本 / URL） |
| `context.app_bundle` | `item.application` |
| `provenance.source_id` / `locator` | `item.id` / `clipcontext:get(<id>)` |
| `privacy.tier` | 默认 `shareable`（能进入 `clipboard.json` 即已由用户在应用内授权共享） |

## 5. 现有缺口（后续增强方向）

1. **缺少窗口标题**：仅有 `application` Bundle ID，从 IDE/浏览器复制时无法直接区分具体项目或页面（需结合 AX API 或与窗口/浏览器渠道时间求交补全）。
2. **缺少粘贴去向（Paste Target）**：尚未追踪复制后切换到了哪个目标 App 粘贴。
3. **无内置 PII 脱敏标签**：依赖用户策略（`manual` / `pinned`）与 Maccy 忽略规则过滤密码管理器，缺少细粒度 `pii_tags`。
