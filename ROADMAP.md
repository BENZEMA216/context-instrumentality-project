# Roadmap · Raw Memory & `X for Agent`

| 阶段 | 核心交付 | 状态 |
| :--- | :--- | :---: |
| **Phase 0 · 仓库重整与规范** | 归档旧 PR/分支、统一 Monorepo 骨架、RFC-0002 与 CI 规范 | ✅ 已完成 |
| **Phase 1 · Raw Memory 核心引擎** | L0 不可变原档 + L1 SQLite FTS5 & 跨源链接 + L2 Episode & Markdown + L3 双时序决策 + **Agent-as-Curator**（Skill + MCP 双闭环）+ Workbench UI | ✅ 已完成 |
| **Phase 2 · 统一存储、品牌归一与核心通道** | L0.5 Blob 仓 + `MEMORY.md` + `get_context_pack` + Checkpoint/Spool 框架 + AI 对话（11 端 No-Echo）+ **Clip for Agent**（PNG 无损压缩 & 正式签名）+ **Read for Agent**（本地 Chrome/Arc/Safari 历史采集器 + MV3 扩展） | ✅ 已完成 |
| **Phase 2.5 · 元记忆评测、公开基准与人工调试闭环** | Hybrid BM25 + Episode↔Turn RRF 升级 + **LongMemEval-S (`96.6%` Sess R@5) / LoCoMo (`72.5%` R@10)** 公开基准集成 + `Project Profiles` 实体层 + 一问一答证据窗口 + Anti-Noise 门禁 + **Human-in-the-Loop Debug Workbench** | ✅ 已完成 |
| **Phase 3 · 录音与聊天通道闭环** | **Record for Agent**（Watch/iPhone + SenseVoice-Small 本地转写）+ **Chat for Agent**（WeFlow / WeChat / Telegram / CSV 合规导入 + 默认 `local_only` + 白名单项目群放行）；后续补齐实时 IM 增量监听 | ✅ 核心已落地（持续打磨） |
| **Phase 4 · Vault for Agent 融合** | 逐条 **AES-256-GCM** 加密孤岛 + Scrypt KDF + `raw-vault run` 零暴露环境变量注入与输出脱敏 + 脱敏指针回执同步；后续补齐 Touch ID 生物解锁与受控 HTTP 白名单代理 | ✅ 核心已落地（持续打磨） |
| **Phase 5 · Focus for Agent 与语义重排演进** | **Focus for Agent**（原生 macOS 前台窗口采样 + ActivityWatch 桥接 + 停留聚类 + 密码/无痕过滤）已落地；下一步补齐本地轻量语义重排（突破零字面重合偏好召回天花板）、记忆生命周期衰减与程序性规则（Procedural Memory）晋升 | 🚧 进行中 |
