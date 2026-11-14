# Record for Agent

用 Apple Watch 随手录下想法，在 iPhone 回听和转写，并将录音保存到自己的云盘，供获得授权的 Agent 使用。

- **Apple Watch** 保存分段录音，并将录音同步到配对的 iPhone。
- **iPhone** 按录音分组查看、播放和管理片段。受支持的 iPhone 可在 iOS 26 或更新系统上本机转写。
- **云盘和 Agent** 可选择 iCloud Drive 或 Google Drive 保存录音和转写。在「同步」页复制所选云盘的接入说明，交给自己选择的 Agent。

[帮助与支持](https://record-for-agent.benzemazdz99.chatgpt.site/support/) · [隐私政策](https://record-for-agent.benzemazdz99.chatgpt.site/privacy/)

## 构建

使用 macOS、带 iOS 和 watchOS SDK 的完整 Xcode，以及 Python 3。本工程最低支持 iOS 18 和 watchOS 11。

```sh
python3 scripts/generate_project.py --check
swift test
bash scripts/build.sh companion
```

使用 Xcode 打开 `WristRecord.xcodeproj`。真机运行需配置自己的签名。Google Drive 需要为自己的 iPhone 应用标识注册 iOS OAuth 客户端。详见[开发配置](docs/development-setup.md)。

| 目录 | 内容 |
| --- | --- |
| `Watch/` | 手表录音、分段保存与向 iPhone 传输 |
| `Phone/` | iPhone 界面、录音库、转写与云盘同步 |
| `Sources/RecordingCore/` | 共享模型、存储与传输协议 |
| `Tests/` | Swift 测试及隔离探针 |
| `AgentBridge/` | 可选的 Mac 接收、转写和只读 MCP 工具 |
| `AgentGateway/` | 可选的网关组件 |

[Agent 接入](docs/agent-onboarding.md) · [iCloud Drive 文件结构](docs/icloud-drive.md) · [Mac 接入工具](AgentBridge/README.md)

提交问题时请使用合成样本或脱敏诊断。配对密钥、云盘凭据、录音、转写和真实设备诊断应保存在自己的设备上。

## 许可证

项目许可证将在公开时公布。
