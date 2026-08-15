---
name: wsl-codex-opencode-orchestrator
description: 在 Windows 上通过指定 WSL2 发行版运行 OpenCode 子 agent 的多任务开发编排技能。适用于用户提供需求或设计文档目录及项目产出目录，希望由 Codex 负责规划、监督和验收，而由 WSL 内 OpenCode 按文件边界并行实现、分段测试并清理进程与 worktree 的场景。
metadata:
  requires:
    bins: [wsl.exe, powershell]
---

# WSL Codex OpenCode Orchestrator

当前阶段只完成 WSL 版架构与详细设计确认，尚未实现 Bash 调度脚本。实施时保持现有 Windows 版技能不变。

## 固定分工

1. Codex 主控负责需求读取、任务图、最小 prompt、调度、监督、Gate 验收、合并和资源回收。
2. WSL 内的 OpenCode 只负责一个子任务的代码实现，不参与任务编排或跨任务协调。
3. 测试 agent 只执行验收，配置为只读，不修改业务代码。
4. 任务运行于同一个指定 WSL2 发行版的多个独立 Linux 进程组，而不是为每个 agent 创建独立 WSL 实例。

## 使用前检查

1. Windows 侧必须存在 `wsl.exe` 和 PowerShell。
2. WSL2 发行版名称必须显式配置，例如 `Ubuntu`，不能依赖默认发行版。
3. WSL 内必须具备 `bash`、`git`、`jq`、`setsid`、`ps`、`pgrep` 和 `opencode`。
4. 项目代码和 worktree 优先放在 WSL Linux 文件系统，例如 `/home/<user>/projects`；`/mnt/c`、`/mnt/d` 仅用于兼容输入。
5. Windows 主机与 WSL 两侧内存准入均通过后才能启动新 agent。

## 设计与实施入口

- [WSL版详细设计文档](C:/Users/y2ksk/.codex/skills/wsl-codex-opencode-orchestrator/详细设计文档.md)
- [[详细设计文档]]
- [技能说明](C:/Users/y2ksk/.codex/skills/wsl-codex-opencode-orchestrator/SKILL.md)
- [[SKILL]]

## 启动原则

使用 Windows 侧的 `wsl.exe -d <DistroName> -- bash -lc ...` 启动 WSL Supervisor。Supervisor 在 WSL 内启动多个 `opencode run` 进程组，并将任务状态写入项目的 `.opencode/` 目录。

在实现完成前，不要将本技能用于无人值守项目开发。
