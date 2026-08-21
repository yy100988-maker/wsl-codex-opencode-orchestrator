---
name: wsl-codex-opencode-orchestrator
description: 在 Windows 上通过指定 WSL2 发行版运行 Linux OpenCode 子 agent 的多任务开发编排技能。当前平台主控 Agent 负责完成任务拆解、最小 prompt、并行调度、分段验收、状态恢复和资源清理。
metadata:
  requires:
    bins: [wsl.exe, powershell]
---

# WSL Codex OpenCode Orchestrator

本文件是本技能的完整运行契约。用户提示词只需要触发技能并提供路径；主控 agent 必须自动加载本文件和相关设计文档，不要求用户重复粘贴完整流程。

## 1. 触发输入

用户通常只需提供：

1. 需求/设计文档目录。
2. 项目产出目标目录。
3. WSL2 发行版名称，默认建议 `Ubuntu`。
4. 可选的关键详细设计文档、接口文档和测试文档文件名。

如果用户没有指定关键文件，主控必须扫描设计文档目录，识别 PRD、详细设计、API、数据库、测试和部署文档。

## 2. 固定职责

### 当前平台主控 Agent

- **只负责调度，不负责写代码。** 主控 agent 绝对不能直接读取业务源文件、不能直接创建或修改业务代码文件。代码实现必须由子 agent 完成。
- 完整读取需求和设计文档一次。
- 建立知识库、项目记忆、任务图和文件映射。
- 拆分任务、生成 `tasks.json` 和每个任务的最小 prompt。
- 通过调度脚本（`admission-cycle.sh`）启动 WSL Supervisor/OpenCode，而不是自己执行开发任务。
- 执行 Gate 验收、合并任务分支、清理资源和生成报告。
- **禁止事项：** 主控 agent 禁止直接读写 `.js`、`.ts`、`.py`、`.vue` 等业务源文件。发现违规必须立即停止，改为将任务分发给子 agent。

### WSL Supervisor

- 运行预检、依赖 Bootstrap、内存准入、Lease、任务启动、状态恢复和回收。
- 不修改业务代码，不重新规划任务。

### OpenCode 实现 agent

- 只实现一个任务。
- 只修改 `allowed_files`/`claimed_files` 范围内的文件。
- 完成任务级测试、handoff 和任务分支提交。
- 不拆任务、不协调其他 agent、不合并代码。

### 测试 agent/Gate

- 只读执行 Scope、Handoff、Static、Unit、Contract、Integration 和 Security 验收。
- 不修改业务代码、不提交业务分支。
- `handoff.completed` 不等于最终完成，必须以 Gate 结果为准。

## 3. 文档加载和 Token 策略

主控必须按以下顺序工作：

1. 读取用户明确指定的详细设计文件。
2. 扫描并读取需求、API、数据库、测试和部署相关文件。
3. 扫描项目结构、Git、包管理器、构建入口和测试入口。
4. 生成项目级摘要和契约锁。
5. 按任务模块生成 `design_slice`，只把对应章节和必要契约传给子 agent。

禁止：

- 每个子 agent 重新读取完整设计文档。
- 将完整项目历史复制到任务 prompt。
- 让子 agent 自行探索全仓库后再决定范围。
- 在重试时重复发送完整 prompt。

状态和记忆必须落盘到：

```text
.opencode/knowledge-base/
.opencode/controller-memory/
.opencode/tasks.json
.opencode/orchestrator-state.json
.opencode/task-graph.jsonl
.opencode/leases.json
```

如果状态快照损坏，必须停止 Supervisor 后使用 `scripts/state-rebuild.sh` 从事件 JSONL 重建，不得手工猜测任务状态。

## 4. 任务拆分契约

主控必须以实际源码文件不并行占用作为最小并行粒度：

1. 先把目录通配符展开为当前仓库实际源码文件，再为每个源码文件生成独立任务；目录通配符不能作为最终并行边界。
2. 同时活跃任务的 `allowed_files`/`claimed_files` 不得重叠；同一源码文件不得被两个 active agent 同时占用。
3. 共享类型、Schema、配置、数据库迁移和入口注册优先生成单文件串行任务。
4. 如果多个原始任务命中同一源码文件，后一个文件任务自动依赖前一个文件任务。
5. 独立模块、service、controller、页面和测试尽量细拆，任务总数可以达到 100+，但实际并发不超过 100。
6. 任务必须记录 `base_commit`、`depends_on`、`source_files`、`source_sections`、`design_slice`、`knowledge_refs`、`acceptance`、`estimated_mb`、`prompt_file` 和 `worktree`。
7. 共享契约必须由主控锁定，不能让多个 agent 各自猜测。

最小任务结构：

```json
{
  "id": "A1-auth-contract",
  "base_commit": "<task-creation-commit>",
  "depends_on": [],
  "allowed_files": ["src/auth/**"],
  "claimed_files": ["src/auth/types.ts"],
  "source_files": ["docs/详细设计文档.md"],
  "source_sections": ["认证模块"],
  "design_slice": "仅认证模块设计需求",
  "prompt_file": ".opencode/prompts/A1-auth-contract.md",
  "worktree": ".opencode/worktrees/A1-auth-contract",
  "estimated_mb": 1024,
  "acceptance": ["认证测试通过"],
  "status": "pending",
  "attempt": 0
}
```

## 5. WSL 环境和启动

所有 OpenCode 子 agent 必须运行在同一个指定 WSL2 发行版内，不为每个 agent 创建独立 WSL 实例，不混用 Windows 原生 `opencode.exe`。主控生成任务后必须执行 `scripts/task-decompose.sh <project-root>`，将目录级任务展开成源码文件级任务，并重新生成每个子任务的最小 prompt。

Supervisor 启动前必须执行 `scripts/ensure-dependencies.sh`、`scripts/ensure-opencode.sh` 和 `scripts/runtime-preflight.sh`。前者自动安装固定白名单中的 `curl`、`git`、`jq`、`util-linux`、`procps` 等系统包；OpenCode Bootstrap 检测并自动安装 WSL Linux 版 OpenCode 到 `~/.opencode/bin`，删除当前用户目录下已确认是 Windows wrapper 的 `~/bin/opencode`，并把 `~/.opencode/bin` 幂等写入 `~/.profile`。运行时预检还必须拒绝 Windows Node/pnpm、悬空 `node_modules` 链接和损坏的 lockfile 物化依赖。安装失败、路径不正确或 `opencode --version` 无法验证必须阻止任务启动。不得自动修改 OpenCode auth、API key、cookie 或模型配置。

项目和高并发 worktree 优先使用 `/home/<user>/projects/<project>`；`/mnt/c`、`/mnt/d` 只作为兼容输入。Supervisor 还必须在 OpenCode 预检后执行 `scripts/runtime-preflight.sh`，检查 Linux 原生 Node/pnpm、lockfile 依赖树和悬空 `node_modules` 链接；必要时使用 `pnpm install --frozen-lockfile` 修复。

预检默认要求项目 Git 工作区干净；如果存在未提交改动，主控必须先建立 baseline commit/patch snapshot，或在配置中显式设置 `wsl.allow_dirty_project=true`。WSL 中的 `opencode` 不能是引用 `/mnt/c`、`/mnt/d`、`powershell.exe` 或 `cmd.exe` 的 Windows 转发脚本。

实际入口：

```powershell
wsl.exe -d <DistroName> -- bash -lc 'cd /home/<user>/projects/<project> && bash /path/to/wsl-codex-opencode-orchestrator/scripts/supervisor-loop.sh .opencode/wsl-config.json'
```

## 6. Agent Provider 和模型回退

WSL 版本支持两种 agent provider：OpenCode 和 xAI Grok CLI。

### Provider 配置

在 `.opencode/wsl-config.json` 中设置：

```json
{
  "agent": {
    "provider": "opencode"
  },
  "models": {
    "implementation": "opencode-go/mimo-v2.5",
    "fallback": "opencode-go/hy3"
  }
}
```

切换到 Grok CLI：

```json
{
  "agent": {
    "provider": "grok"
  },
  "models": {
    "implementation": "grok-4",
    "fallback": "grok-4"
  }
}
```

### OpenCode 模式

- 主模型：`opencode-go/mimo-v2.5`。
- 备用模型：`opencode-go/hy3`。
- 命令格式：`opencode run --model <model> --format json --file <prompt>`

### Grok CLI 模式

- 需要在 WSL 中安装 grok wrapper：`~/bin/grok` 指向 `/mnt/d/Program Files/grok/grok.exe`。
- 命令格式：`grok agent --cwd <worktree> --prompt-file <prompt> --model <model> --output-format streaming-json --no-subagents --permission-mode auto --max-turns 30`
- Grok CLI 使用自身模型和配置，不套用 OpenCode 的模型回退规则。

### 回退规则

- 主模型发生模型不存在、provider 不可用或启动即失败时，只回退一次。
- 备用模型失败后进入有限重试或 `blocked`，禁止无限创建进程。
- 回退事件必须写入 `task-graph.jsonl`。

## 7. 30 秒资源监控

主控生成或修正 `.opencode/wsl-config.json` 时，必须设置：

```json
{
  "scheduler": {
    "monitor_interval_seconds": 30
  }
}
```

Supervisor 默认也使用 30 秒。每轮检查 WSL 内存和 swap、Windows 主机内存、active/退出/失联 agent、文件 Lease、依赖状态、PID/PGID、Gate、handoff、日志和重试次数。

准入规则：

- WSL 或 Windows 任一侧达到 88%：停止新增任务。
- 任一侧达到 90%：优先 Gate、清理和释放资源。
- 两侧低于 80%：恢复新增任务。
- 同时满足依赖、文件不冲突、并发上限、Lease 和双层内存保护才可启动。
- Supervisor 默认启用 `max_task_runtime_seconds=7200` 和 `stall_timeout_seconds=600`；超时任务必须停止、归档、释放 Lease 并标记 `blocked`。只有明确配置为更长时间才可放宽，不能用 `0` 关闭无人值守批次的超时保护。

## 8. 进程、worktree 和 Lease 清理

每个任务必须拥有独立的进程组、worktree、Lease、日志和状态记录。任务完成、失败、超时、取消或失联时：

1. 校验任务 PID、PGID、启动时间和 worktree 路径。
2. 只向当前任务进程组发送 SIGTERM。
3. 等待宽限期后仍存活才发送 SIGKILL。
4. Gate 通过后删除受控 worktree；失败任务归档。
5. 释放 Lease，更新历史和事件。
6. 生成或刷新资源清理报告。

禁止使用：

```bash
pkill node
pkill bun
pkill esbuild
```

## 9. Handoff 和 Gate

实现 agent 必须在 worktree 根目录写入 `.opencode-handoff.json`，至少包含：

```json
{
  "task_id": "A1-auth-contract",
  "status": "completed",
  "changed_files": [],
  "validation_commands": [],
  "validation_result": "passed",
  "known_blockers": []
}
```

Gate 必须基于任务创建时固定的 `base_commit` 验证 changed files 是否越过允许范围、handoff 是否有效、任务测试和静态检查是否通过、是否存在契约/安全违规，以及任务进程、Lease 和 worktree 是否满足回收条件。空分支、空合并和必需 Gate 的 `not-configured` 都必须失败；合并后还要验证 changed files 已进入目标分支，只有全部通过后主控才可标记 done。

## 10. 恢复和完成条件

WSL Linux 项目目录是任务状态和代码的唯一事实来源。需要更新 Windows 交付镜像时，主控执行 `scripts/delivery-sync.sh <config>`；该命令只同步 tasks、状态、Gate、报告、归档、prompt 和项目记忆，并先备份目标 `.opencode`，不得覆盖业务代码。

任务归档必须包含 `manifest.json`、`hashes.sha256`、`changes.patch` 和 untracked 文件副本；恢复时使用 `scripts/worktree-manager.sh restore`，恢复后必须重新运行 Gate。

Supervisor 重启时，主控必须读取状态快照、事件、Lease、Gate、handoff 和项目记忆，不重复启动已完成任务，不重复传递完整设计文档。

批次完成必须生成：

```text
开发完成报告.md
测试验收报告.md
阻塞项报告.md
资源清理报告.md
Token与执行成本报告.md
```

## 11. 用户短提示词

### 方式一：设计文档目录 + 产出目录

```text
使用 wsl-codex-opencode-orchestrator 启动项目开发。

需求/设计文档目录：D:\项目\docs
详细设计文档：D:\项目\docs\详细设计文档.md
项目产出目标目录：D:\项目\workspace
WSL2 发行版：Ubuntu

请加载本技能的完整执行规则，自动生成任务图、tasks.json、知识库和子任务 prompt；按文件边界并行调用 WSL 内 OpenCode，每 30 秒监控资源，执行 Gate 验收，并在完成后清理进程、worktree 和 Lease。
```

### 方式二：单文件设计文档 + 现有工作区

```text
$wsl-codex-opencode-orchestrator 你是主控agent，请根据设计文档：<设计文档绝对路径>
产出物路径：<现有项目工作区或指定路径>
WSL2 发行版：Ubuntu
完成文档中所有功能开发和自动化测试。
```

### 方式三：一行完整指令

```text
$wsl-codex-opencode-orchestrator 你是主控agent，请根据设计文档：<文档路径> 产出物路径：<本工作区或指定路径>，完成文档中所有功能开发和自动化测试。
```

**重要：主控 agent 只负责调度，不直接写代码。** 所有代码实现必须通过 `admission-cycle.sh` 分发给 WSL 内的 OpenCode 子 agent 执行。

### 继续任务

```text
使用 wsl-codex-opencode-orchestrator 继续执行。

项目产出目标目录：D:\项目\workspace
WSL2 发行版：Ubuntu

请读取 .opencode/ 中的任务、状态、Lease、Gate、handoff 和项目记忆，恢复未完成任务；不要重复已完成任务，按本技能规则每 30 秒监控、验收和清理。
```

## 12. 文档入口

- [README](README.md) / `[[README.md]]`
- [使用说明](使用说明.md) / `[[使用说明.md]]`
- [快速开始](docs/快速开始.md) / `[[快速开始.md]]`
- [配置参考](docs/配置参考.md) / `[[配置参考.md]]`
- [任务协议](docs/任务协议.md) / `[[任务协议.md]]`
- [运行机制](docs/运行机制.md) / `[[运行机制.md]]`
- [故障排查](docs/故障排查.md) / `[[故障排查.md]]`
- [详细设计文档](详细设计文档.md) / `[[详细设计文档.md]]`
