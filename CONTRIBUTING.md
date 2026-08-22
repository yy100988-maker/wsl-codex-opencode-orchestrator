# 贡献指南

文档导航：[README](README.md) / `[[README.md]]`， [运行机制](docs/运行机制.md) / `[[运行机制.md]]`， [安全说明](SECURITY.md) / `[[SECURITY.md]]`。

## 修改范围

- 运行时脚本必须保持 Bash 可执行，并兼容 Ubuntu WSL2。
- 不修改 Windows 版 `codex-opencode-orchestrator`。
- 不把 `.opencode/` 运行产物、日志、凭据或模型响应提交到仓库。
- 进程清理必须基于任务级 PID/PGID 和启动时间，禁止全局杀进程。
- 测试 agent 的只读边界不能被放宽。

## 本地验证

```bash
bash -n scripts/*.sh tests/orchestrator-smoke.sh
bash tests/orchestrator-smoke.sh
git diff --check
```

如果修改了配置解析、Lease、进程清理或 Gate，需要增加对应的 smoke 场景。

## 版本管理

- 版本格式：`X.Y.Z`（SemVer 简化版），当前起点 `0.1.0`。
- 每次更新代码或文档后，只递增第三位：`0.1.0` → `0.1.1` → `0.1.2`，依此类推。
- 第二位和第一位仅在用户显式要求时才允许升级。
- 发版流程：更新 `SKILL.md` frontmatter 的 `version` 字段 → 提交 → 打 tag `vX.Y.Z` → 推送到 GitHub → 同步本地 skill。
## 提交说明

提交信息使用简短、明确的动词，例如：

```text
feat: add WSL dependency bootstrap
fix: prevent duplicate task admission
docs: clarify gate failure recovery
```

提交前确认：

1. 变更文件没有超出本次目标。
2. 没有真实凭据或本机路径泄露。
3. 文档中的命令与脚本参数一致。
4. 运行结果和未覆盖风险已写入提交说明或 PR 描述。
