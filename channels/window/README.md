# Focus for Agent · 窗口焦点通道

实现位于 [`packages/collectors/src/context_collectors/window.py`](../../packages/collectors/src/context_collectors/window.py)：

- **双后端支持**：
  1. 若本机运行 ActivityWatch（`http://127.0.0.1:5600`），自动增量拉取 `aw-watcher-window` 事件；
  2. 否则自动回退至零依赖 macOS 原生前台窗口采样（`osascript` + `ioreg` `HIDIdleTime` 空闲检测）。
- **停留会话聚类（Session Coalescing）**：自动合并连续同窗口采样，过滤 `< 10s` 的高频切窗抖动。
- **隐私硬防护**：自动丢弃密码管理器（1Password / Bitwarden / Keychain）、锁屏界面和无痕/隐私浏览窗口；邮件与即时通讯窗口默认标为 `local_only`。
- **命令**：`uv run raw-collectors doctor --collector window` / `uv run raw-collectors watch --collector window --interval 15`
