# 本地开发

在 macOS 上安装带 iOS、watchOS SDK 的完整 Xcode 和 Python 3。使用 `xcode-select` 选择 Xcode，或为构建命令指定 `DEVELOPER_DIR`。

```sh
python3 scripts/generate_project.py --check
swift test
bash scripts/build.sh companion
```

`companion` 构建包含手表组件的无签名 iPhone App。`bash scripts/build.sh phone` 只构建 iPhone 模拟器验证目标。

## 真机和云盘

1. 将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`。填写自己的 Apple 开发团队和唯一应用标识前缀。
2. 用 Xcode 打开 `WristRecord.xcodeproj`，选 `WristRecordPhone`，目标设为与 Apple Watch 配对的 iPhone。手表单独调试可选 `WristRecordWatch`。
3. 若要使用 Google Drive，将 `Config/GoogleDrive.local.xcconfig.example` 复制为 `Config/GoogleDrive.local.xcconfig`。为实际 iPhone bundle ID 注册 iOS OAuth 客户端，启用 Google Drive API，并配置 `drive.file` 所需的授权。
4. 在 iPhone 的「同步 → 保存到」选择所需云盘。iCloud Drive 通过系统「文件」选择器授权，Google Drive 通过 Google OAuth 授权。

构建使用的本地配置已被 Git 忽略。升级自己的真机测试安装时，请使用相同的应用标识和签名团队，以保留 App 容器。

## 组件验证

Swift 共享核心与手表音频测试使用 `swift test`。部分 Phone 和 Watch 隔离探针带有独立脚本，执行前可查看各目录的 README 或参数。可选 Mac 组件运行 `python3 -B -m unittest discover -s AgentBridge/tests`。可选网关的本地检查见 [AgentGateway](../AgentGateway/README.md)。
