# 剪切板（ClipContext）

已并入 [clipcontext](clipcontext)（ClipContext 0.1.1，MIT 许可证，基于 Maccy）。

## 已有能力

- macOS 菜单栏剪切板历史、搜索、收藏板与顺序粘贴。
- 用户可控的共享策略（默认 `off`，支持 `manual` / `pinned` / `all`），导出快照 `Agent/clipboard.json`（支持本机目录、iCloud Drive、Google Drive）。
- 只读 stdio MCP（`Agent/clipcontext-mcp.py`）：`recent`、`search`、`get`。
- 增量简报（`Agent/clipcontext-digest.py`）：按 `revision` + 条目 SHA-256 指纹追踪新增/变更/撤销条目。

## 验证与研究

```sh
cd clipcontext && python3 -B -m unittest discover -s Agent -v
```

数据模型与接入分析见 [docs/research/channel-clipboard.md](../../docs/research/channel-clipboard.md)。
