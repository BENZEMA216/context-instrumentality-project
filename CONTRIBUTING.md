# 贡献与开发指南

## 环境准备
- Python 3.12+ 与 [`uv`](https://docs.astral.sh/uv/)
- Node.js 22+（用于构建 `web/` 工作台与 `extensions/browser/` 扩展）
- macOS 14+ 与 Xcode Command Line Tools（用于 `native/macos/` 原生组件）

## 日常开发
```sh
uv sync --all-extras
uv run pytest
uv run ruff check .
```

## 协作规则
- 分支命名：`<type>/<short-slug>`，直接基于 `main` 创建，合并后清理分支。
- 契约优先：修改事件或 MCP 协议时先更新 `schema/` 并补充测试。
- 隐私红线：严禁提交任何个人真实上下文数据或密钥，所有测试均基于合成样例。
- 详见 [AGENTS.md](AGENTS.md) 与 [RFC-0002](docs/rfc/0002-hub-v2-agent-curator.md)。
