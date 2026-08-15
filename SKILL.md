---
name: wsl-codex-opencode-orchestrator
description: 在 Windows 上通过指定 WSL2 发行版运行 OpenCode 子 agent 的多任务开发编排技能。适用于用户提供需求或设计文档目录及项目产出目录，希望由 Codex 负责规划、监督和验收，而由 WSL 内 OpenCode 按文件边界并行实现、分段测试并清理进程与 worktree 的场景。
metadata:
  requires:
    bins: [wsl.exe, powershell]
---

# WSL Codex OpenCode Orchestrator

本技能已实现 WSL Bash 调度运行时。它保持现有 Windows 版技能不变，使用同一个指定 WSL2 发行版承载多个独立 OpenCode 进程组。

## 固定分工

1. Codex 主控负责需求读取、任务图、最小 prompt、调度、监督、Gate 验收、合并和资源回收。
2. WSL 内的 OpenCode 只负责一个子任务的代码实现，不参与任务编排或跨任务协调。
3. 测试 agent 只执行验收，配置为只读，不修改业务代码。
4. 任务运行于同一个指定 WSL2 发行版的多个独立 Linux 进程组，而不是为每个 agent 创建独立 WSL 实例。

## 使用前检查

1. Windows 侧必须存在 `wsl.exe` 和 PowerShell。
2. WSL2 发行版名称必须显式配置，例如 `Ubuntu`，不能依赖默认发行版。
3. WSL 内必须具备 `bash`、`git`、`jq`、`setsid`、`ps`、`pgrep`、`flock` 和 `opencode`。缺少 `jq` 时请先在 Ubuntu 内执行 `sudo apt-get update && sudo apt-get install -y jq`。
4. 项目代码和 worktree 优先放在 WSL Linux 文件系统，例如 `/home/<user>/projects`；`/mnt/c`、`/mnt/d` 仅用于兼容输入。
5. Windows 主机与 WSL 两侧内存准入均通过后才能启动新 agent。

## 设计与实施入口

- [WSL版详细设计文档](C:/Users/y2ksk/.codex/skills/wsl-codex-opencode-orchestrator/详细设计文档.md)
- [[详细设计文档]]
- [技能说明](C:/Users/y2ksk/.codex/skills/wsl-codex-opencode-orchestrator/SKILL.md)
- [[SKILL]]

## 运行入口

在 WSL 内准备 `.opencode/wsl-config.json` 和 `.opencode/tasks.json` 后，从 Windows 侧启动：

```powershell
wsl.exe -d Ubuntu -- bash -lc 'cd /home/<user>/projects/<project> && bash /path/to/wsl-codex-opencode-orchestrator/scripts/supervisor-loop.sh .opencode/wsl-config.json'
```

Supervisor 会先执行预检，再按依赖、文件租约、WSL 内存和 Windows 主机内存准入任务；每个任务使用独立 worktree 和进程组。任务结束后运行 Gate，只有通过才合并任务分支，否则归档 worktree 并释放租约。

单独检查环境：

```bash
bash scripts/preflight.sh /path/to/project/.opencode/wsl-config.json
```

生成资源清理报告：

```bash
bash scripts/report-builder.sh /path/to/project
```

实现 agent 使用 `opencode-go/deepseek-v4-flash`，启动失败时只回退一次到 `opencode-go/gpt-5.6-luna`。测试 Gate 读取 `.opencode-handoff.json` 和任务测试命令，不允许测试 agent 修改业务文件。

## 启动原则

使用 Windows 侧的 `wsl.exe -d <DistroName> -- bash -lc ...` 启动 WSL Supervisor。Supervisor 在 WSL 内启动多个 `opencode run` 进程组，并将任务状态写入项目的 `.opencode/` 目录。

首次运行建议先执行 `preflight.sh` 和 smoke 测试；预检失败时禁止启动无人值守开发。
