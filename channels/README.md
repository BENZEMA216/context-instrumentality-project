# Channels · `X for Agent` 采集通道总览

| 渠道 | 产品名 | 核心实现 | 状态 |
| :--- | :--- | :--- | :---: |
| 🤖 AI 对话历史 | `ai_chat` Collector | [`packages/collectors/src/context_collectors/ai_chat/`](../packages/collectors/src/context_collectors/ai_chat/) | ✅ 已落地（11 端 + No-Echo） |
| 🎙️ 语音录音 | **[`Record for Agent`](https://github.com/rawmemory/record-for-agent)** | [`packages/collectors/src/context_collectors/audio/`](../packages/collectors/src/context_collectors/audio/) | ✅ 已落地（本地 SenseVoice ASR） |
| 📋 剪贴板 | **[`Clip for Agent`](https://github.com/rawmemory/ClipContext)** | [`packages/collectors/src/context_collectors/clipcontext.py`](../packages/collectors/src/context_collectors/clipcontext.py) | ✅ 已落地（PNG 压缩 + 来源 URL） |
| 🌐 浏览器阅读 | **`Read for Agent`** | [`browser.py`](../packages/collectors/src/context_collectors/browser.py) · [`extensions/browser/`](../extensions/browser/) | ✅ 已落地（无锁历史 + MV3 扩展） |
| 🖥️ 窗口焦点 | **`Focus for Agent`** | [`window.py`](../packages/collectors/src/context_collectors/window.py) | ✅ 已落地（macOS 原生 + AW 桥接） |
| 💬 聊天记录 | **`Chat for Agent`** | [`chat.py`](../packages/collectors/src/context_collectors/chat.py) | ✅ 核心已落地（WeFlow/IM 合规导入） |
| 🔐 加密私密库 | **`Vault for Agent`** | [`packages/vault/`](../packages/vault/README.md) | ✅ 核心已落地（AES-256-GCM + 零暴露注入） |

每个渠道最终输出 [统一事件 Schema](../schema/context-event.schema.json)，通过 `uv run raw-collectors doctor|sync|watch` 统一体检与增量同步。
