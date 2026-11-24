# Vault for Agent (`packages/vault`)

隔离式个人加密私密库与零暴露 Agent 代办执行器（对应 [Issue #3](https://github.com/rawmemory/context-instrumentality-project/issues/3)）：

- **逐条 AES-256-GCM 认证加密**：每条记录独立随机 96-bit Nonce + `record_id:kind:version` AAD 防密文置换，主密钥经 Scrypt KDF 派生，密文隔离存放在 `~/.local/share/context-hub-v2/vault/vault.sqlite3`（`0600` 权限），明文永不进入 Raw Memory SQLite 或日志。
- **零暴露命令注入（`raw-vault run`）**：内存中解密后仅注入子进程环境变量，校验 `allowed_commands` 白名单，并对子进程 `stdout`/`stderr` 中任何意外回显的密钥字面量自动脱敏为 `***VAULT_REDACTED***`，同时写入完整审计日志。
- **脱敏指针回执同步（`raw-vault sync-receipts`）**：仅向 Raw Memory 写入非敏感指针（如 `vault_xxx` 的标签与调用方式），让 Agent 知道凭证存在但永远看不到明文。

## 用法

```bash
# 初始化加密库
uv run raw-vault init

# 存入密钥（通过环境变量或交互密文输入，避免进入 shell history）
MY_KEY="sk-..." uv run raw-vault set --kind api_key --label "OpenAI Key" --value-env MY_KEY --allow-cmd curl --project raw-memory

# 仅查看非敏感元数据（无需解锁密码）
uv run raw-vault list

# 向 Raw Memory 同步脱敏指针回执
uv run raw-vault sync-receipts

# 零暴露注入执行命令（任何意外回显自动替换为 ***VAULT_REDACTED***）
uv run raw-vault run --secret OPENAI_API_KEY=vault_... -- curl -s https://api.openai.com/v1/models
```
