# Mac 配对接收

iPhone 的「同步 → 保存到 → 电脑」可以将已收到的录音发送到你配对的 Mac。接收端设置见 [AgentBridge](../AgentBridge/README.md)。首次使用时，从 Mac 获取配对资料，在 iPhone 的电脑同步设置中添加接收端。iPhone 与 Mac 需要能互相访问，iOS 提示时请允许本地网络访问。

每台电脑有独立的授权、队列和保存回执，可以分别暂停和解除配对。手机保留原录音。Mac 可以转写已授权且已保存的音频，随后由选择的 Agent 通过只读 MCP 访问录音库。多个 Agent 可以使用同一台 Mac 上的接收端。

Mac 保存回执表示收到并持久保存了对应内容。Agent 何时读取和处理取决于客户端。Mac 保存的转写可通过[回流接口](receiver-transcript-return.md)返回手机。
