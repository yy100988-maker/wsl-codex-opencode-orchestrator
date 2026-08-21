#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
root="${1:?project root}"; state="$root/.opencode/orchestrator-state.json"; out="$root/.opencode/reports/资源清理报告.md"; mkdir -p "$(dirname "$out")"
 {
   printf '# 资源清理报告\n\n生成时间：%s\n\n' "$(wsl_now)"
   printf '| 任务 | 状态 | 进程记录 | Gate | Lease |\n|---|---|---|---|---|\n'
   jq -r '.history[] | "| `\(.task_id)` | \(.status) | [process](../processes/\(.task_id).json) | [gate](../gates/\(.task_id)/result.json) | [lease](../leases.json) |"' "$state" 2>/dev/null || true
   printf '\n## 资源采样\n\n'
   if [[ -f "$root/.opencode/metrics/memory.jsonl" ]]; then
     printf '| 时间 | WSL 使用率 | Windows 使用率 | 可用主机内存 | 活跃任务 |\n|---|---:|---:|---:|---:|\n'
     jq -r '"| \(.sampled_at) | \(.wsl_used_percent)% | \(.host_used_percent)% | \(.host_available_mb) MB | \(.active) |"' "$root/.opencode/metrics/memory.jsonl" 2>/dev/null || true
   else
     printf '暂无内存采样。\n'
   fi
   printf '\n## 健康采样\n\n'
   if [[ -f "$root/.opencode/metrics/health.jsonl" ]]; then
     printf '| 任务 | PID | 进程名 | 状态 | 内存 (MB) | CPU (秒) | 日志龄 (分) | 采样时间 |\n|---|---:|---|---|---:|---:|---:|---|\n'
     jq -r '"| `\(.task_id)` | \(.pid) | \(.process_name) | \(.status) | \(.memory_mb) | \(.cpu_seconds) | \(.log_age_minutes) | \(.sampled_at) |"' "$root/.opencode/metrics/health.jsonl" 2>/dev/null || true
   else
     printf '暂无健康采样。\n'
   fi
 } > "$out"
 printf '%s\n' "$out"
