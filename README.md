# ClipContext

基于 [Maccy](https://github.com/p0deje/Maccy) 的 macOS 剪贴板管理应用，提供历史搜索、收藏板、富文本与纯文本粘贴、顺序粘贴，以及由用户控制的云盘共享和 Agent 读取。

当前版本：**0.1.1（build 2）**。支持 macOS 14.0 或以上；现成安装包适用于 Apple Silicon（arm64）。

## 下载与使用

- [下载 0.1.1 试用版](https://github.com/BENZEMA216/ClipContext/releases/tag/v0.1.1)：解压后可看到应用和两份 Markdown 说明。
- [使用说明](使用说明.md)：安装、操作、快捷键、共享、云盘和 Agent 配置。
- [Bug 反馈说明](<Bug 反馈说明.md>) · [提交问题](https://github.com/BENZEMA216/ClipContext/issues/new/choose)。
- [完整 HTML 手册](docs/ClipContext-Full-Guide.html)：下载后可在浏览器打开。

试用版采用 ad-hoc 签名，未做 Developer ID 公证。共享默认关闭；直接粘贴和顺序粘贴需要辅助功能权限。

## 主要功能

- 剪贴板历史、搜索、收藏及卡片/列表两种布局。
- 富文本、纯文本、图片、文件引用和顺序粘贴。
- 用户选择共享范围，支持本机目录、iCloud Drive 和 Google Drive 快照。
- 只读 MCP 与增量简报，可与 Codex 或 Claude Code CLI 配合使用。

云盘保存共享目录的单向快照，不自动恢复或合并本地剪贴板历史。Google Drive 需自行配置 OAuth 客户端并授权；简报需可用且已登录的对应 CLI。

## 源码结构

| 路径 | 内容 |
| --- | --- |
| `Maccy.xcodeproj` | Xcode 工程；scheme 为 `Maccy`，产物为 `ClipContext.app` |
| `Maccy/` | Swift 源码、图标、模型和多语言资源 |
| `MaccyTests/`、`MaccyUITests/` | 原生单元测试与 UI 测试 |
| `Agent/` | MCP、简报脚本、Python 测试及传输测试 |
| `scripts/` | 构建、签名、打包和 ZIP 文件名处理 |
| `docs/` | 用户文档、第三方声明和注明日期的历史开发报告 |
| `Designs/` | 上游设计资源 |

## 构建

本地检查环境为 Xcode 27.1 / Swift 6.4，脚本和 Agent 工具需要 Python 3。锁定的部分依赖要求至少 Swift 6.2 工具链；较旧 Xcode 版本尚未验证。首次构建需要联网获取 Swift Package 依赖，`Package.resolved` 已纳入版本控制。

```sh
git clone https://github.com/BENZEMA216/ClipContext.git
cd ClipContext
open Maccy.xcodeproj
```

在 Xcode 中选择 `Maccy` scheme 和当前 Mac。直接运行或测试时，在 Signing & Capabilities 中选择自己的开发团队。

也可使用脚本构建到独立目录：

```sh
CLIPCONTEXT_INSTALL_DIR="$PWD/.build/install" ./scripts/build-mvp.sh
```

脚本采用 Debug / arm64 配置，生成 `.build/install/ClipContext.app` 和 `Dist/ClipContext.zip`；ZIP 自动包含两份 Markdown。省略 `CLIPCONTEXT_INSTALL_DIR` 时，默认安装或替换 `~/Applications/ClipContext.app`。

## 测试

```sh
python3 -B -m unittest discover -s Agent -v
```

当前源码快照的 20 项 Agent Python 测试通过。工程文件、打包脚本、依赖锁和资源引用已检查。原生测试与 UI 测试可在 Xcode 的 Test 导航中运行；UI 测试会操作桌面和剪贴板，宜在独立测试账户中执行。

本次上传沿用已经验证签名的 0.1.1 安装包，没有重新编译应用或重新执行完整 UI 验收。`docs/` 中的开发报告是历史记录，其中的本机测试日志和备份不随仓库提供。运行时剪贴板数据、凭据、构建缓存和旧安装包不纳入 Git；安装包通过 Releases 提供。

## 开源归属

本项目基于 Maccy，保留其 [MIT 许可证](LICENSE)及版权声明。[README.source.md](README.source.md) 保留上游历史介绍；其中的 Maccy 下载、支持和赞助入口属于上游项目。ClipContext 请使用本页的下载和反馈链接。第三方组件声明见 [ThirdPartyNotices.txt](docs/ThirdPartyNotices.txt)。
