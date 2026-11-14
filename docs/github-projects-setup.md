# GitHub Projects 看板搭建与批量导入指南

本指南帮助你用 **GitHub 原生 Projects (V2) + Milestones + Issues** 把 `open-context` 的研发与社区协作跑起来。

---

## 第一步：创建 GitHub 仓库与本地绑定

1. 在 GitHub 上创建一个新仓库（例如 `<OWNER>/open-context`）。
2. 将当前 `open-context/` 目录初始化并推送到 GitHub：

```bash
cd open-context
git init -b main
git add .
git commit -m "chore: bootstrap open-context roadmap, issue templates, and project setup"
git remote add origin https://github.com/<OWNER>/open-context.git
git push -u origin main
```

---

## 第二步：创建 GitHub Project V2 并配置自定义字段

在 GitHub 网页端进入仓库的 **Projects** 标签页 → **New project**（选择 `Board` 或 `Table` 模板均可），建议配置以下自定义字段（Settings → Custom fields）：

| 字段名 | 类型 | 建议选项 |
| :--- | :--- | :--- |
| **Status** | Single select（默认自带） | `Backlog`, `Ready`, `In Progress`, `In Review`, `Done` |
| **Module** | Single select | `channels`, `integration`, `evaluation`, `oss`（M1 之后再增加工程模块） |
| **Priority** | Single select | `P0`, `P1`, `P2` |
| **Effort** | Single select | `S`, `M`, `L` |

### 推荐创建的 4 个看板视图（Views）

1. **`Research Board`（Board 视图）**：Filter 选 `milestone:"M0: Research - Channels & Integration Method"`，Column 按 `Status` 分组，是当前阶段的主视图。
2. **`Parallel Tracks`（Board 视图）**：Column 按 `Module` 分组 —— 一眼看清 4 条并行开发线（`hub` / `mac-daemon` / `browser-ext` / `audio-bridge`）谁被阻塞、谁可并行认领。
3. **`All Backlog`（Table 视图）**：按 `Milestone` 分组、按 `Priority` 排序 —— 宏观排期与优先级评估。
4. **`Roadmap`（Roadmap 视图）**：按 `Milestone` 展示四个阶段的时间跨度与交付节奏。

---

## 第三步：运行 `bootstrap_github.py` 批量导入 Labels / Milestones / Issues

### 1. 确保 `gh` CLI 已登录且拥有 `project` 权限

```bash
gh auth status
# 如需脚本自动把 Issue 加进 Project V2 并回填自定义字段，需确保授权包含 project scope：
gh auth refresh -s project
```

### 2. 先离线校验与 `--dry-run` 预演

```bash
# 校验 project/issues.json 内部依赖、标签与里程碑引用是否合法
python3 scripts/bootstrap_github.py --validate-only

# 预演将要执行的 gh 命令（不修改任何 GitHub 远端数据）
python3 scripts/bootstrap_github.py \
  --repo <OWNER>/open-context \
  --project-number 1 \
  --project-owner <OWNER> \
  --dry-run
```

### 3. 正式执行导入（支持幂等重跑）

```bash
python3 scripts/bootstrap_github.py \
  --repo <OWNER>/open-context \
  --project-number 1 \
  --project-owner <OWNER>
```

> **提示**：脚本会自动跳过同名的 Milestone 与同标题的 Issue，可以安全重跑。当前只有 M0 研究任务；M1 及之后的 Issue 会在 RFC 0001 通过后再拆。

---

## 第四步：启用新 Issue / PR 自动入看板（GitHub Actions）

仓库已包含 [.github/workflows/project-auto-add.yml](../.github/workflows/project-auto-add.yml)。启用步骤：

1. 打开仓库 **Settings → Secrets and variables → Actions**：
   - 在 **Variables** 中新增 `PROJECT_URL`，值为你的 Project 链接，例如 `https://github.com/users/<OWNER>/projects/1`（或组织 Project 链接）。
   - 在 **Secrets** 中新增 `ADD_TO_PROJECT_TOKEN`：一个具有 `project` 和 `repo` 权限的 Fine-grained / Classic PAT（GitHub 默认 `GITHUB_TOKEN` 无法写入用户级 Project V2）。
2. 配置完成后，所有通过 Issue 模板新提交的 Issue 与 PR 都会自动进入你的 Project 看板。
