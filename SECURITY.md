# 安全说明

文档导航：[README](README.md) / `[[README.md]]`， [配置参考](docs/配置参考.md) / `[[配置参考.md]]`， [故障排查](docs/故障排查.md) / `[[故障排查.md]]`。

## 凭据

- 不要把 API key、token、cookie、SSH 私钥或 OpenCode auth 文件提交到仓库。
- 不要把凭据写入 `wsl-config.json`、任务 prompt、handoff、日志或事件文件。
- OpenCode 认证必须在目标 WSL 用户环境中完成；Windows 凭据不会被复制。
- 报告问题时使用 `[REDACTED_SECRET]` 替换真实凭据。

## 进程隔离

每个任务使用独立进程组。清理前必须校验任务 PID、PGID 和启动时间，防止 PID 复用造成误杀。禁止使用全局进程名清理。

## 文件边界

`allowed_files` 是实现 agent 的最小写入边界。Gate 必须检查 changed files；发现越界时任务不能合并。共享入口文件、配置文件和迁移文件应设置为串行任务。

## 权限与自动安装

自动安装仅针对固定 Ubuntu 系统包：`git`、`jq`、`util-linux` 和 `procps`。脚本不会自动安装 OpenCode，不会自动执行 `opencode auth`，也不会修改模型配置。任何 root 回退只用于安装这些系统包。

## 报告漏洞

不要在公开 issue 中发布凭据、完整日志或可复现的生产路径。请先删除敏感信息，再通过仓库维护者可用的私下渠道提交问题。
