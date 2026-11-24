# Read for Agent · 浏览器通道

双轨采集架构，同时覆盖“零配置即用”与“深度正文抽取”：

1. **本地无锁历史采集器**（[`packages/collectors/src/context_collectors/browser.py`](../../packages/collectors/src/context_collectors/browser.py)）：
   - 自动发现 Chrome / Arc / Brave / Edge / Safari 历史数据库，通过临时快照只读查询，永不锁死浏览器。
   - 内置认证/OAuth/搜索跳转去噪与敏感域名（网银、邮箱、密码管理器）自动 `local_only` 隐私隔离。
   - 自动规范化 URL 并与 `Clip for Agent`（`org.chromium.source-url`）和 AI 对话产生跨源锚点链接。
   - 命令：`uv run raw-collectors sync --collector browser --since-days 7`
2. **Chrome / Arc MV3 深度阅读扩展**（[`extensions/browser/`](../../extensions/browser/README.md)）：
   - 三层有效停留门禁 + Defuddle 正文转 Markdown + 隐式划词提权 + Promnesia 关联侧边栏。
