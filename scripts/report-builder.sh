#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
root="${1:?project root}"; state="$root/.opencode/orchestrator-state.json"; out="$root/.opencode/reports/资源清理报告.md"; mkdir -p "$(dirname "$out")"
{
 printf '# 资源清理报告\n\n生成时间：%s\n\n' "$(wsl_now)"
 printf '| 任务 | 状态 | 进程记录 | Gate |\n|---|---|---|---|\n'
 jq -r '.history[] | "| `\(.task_id)` | \(.status) | [process](../processes/\(.task_id).json) | [gate](../gates/\(.task_id)/result.json) |"' "$state" 2>/dev/null || true
} > "$out"
printf '%s\n' "$out"
