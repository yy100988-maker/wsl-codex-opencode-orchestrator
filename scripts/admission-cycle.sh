#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config}"; root="$(jq -r '.wsl.project_root' "$config")"; state="$root/.opencode/orchestrator-state.json"; tasks="$root/.opencode/tasks.json"
wsl_ensure_state_dirs "$state"; "$SCRIPT_DIR/lease-manager.sh" purge "$state" _ >/dev/null
max="$(jq -r '.scheduler.max_concurrent_agents' "$config")"; active="$(jq '[.active[] | select(.status=="running")] | length' "$state")"; slots=$((max-active)); (( slots > 0 )) || exit 0
stop="$(jq -r '.memory.windows_stop_admission_percent' "$config")"; critical="$(jq -r '.memory.windows_critical_percent' "$config")"; reserve="$(jq -r '.memory.windows_reserve_mb' "$config")"
host_json="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/host-memory-guard.ps1" -StopAdmissionPercent "$stop" -CriticalPercent "$critical" -ReserveMB "$reserve" 2>/dev/null | tr -d '\r')"
[[ "$(jq -r '.admission_allowed' <<<"$host_json")" == true ]] || { wsl_append_event "$state" admission-paused _ "$host_json"; exit 0; }
used="$(free | awk '/Mem:/ {printf "%.0f", (($2-$7)/$2)*100}')"; wsl_stop="$(jq -r '.memory.wsl_stop_admission_percent' "$config")"; (( used < wsl_stop )) || exit 0
finished="$(jq -c '[.history[] | select(.status == "done" or .status == "blocked") | .task_id]' "$state")"
while (( slots > 0 )); do
 task="$(jq -c --argjson finished "$finished" '[.tasks[] | select((.status // "pending") == "pending" and ((.id as $id | ($finished | index($id))) == null))] | first // empty' "$tasks")"; [[ -n "$task" && "$task" != null ]] || break
 id="$(jq -r '.id' <<<"$task")"; wt="$root/.opencode/worktrees/$id"; prompt="$root/.opencode/prompts/$id.md"; files="$(jq -c '.allowed_files // []' <<<"$task")"
 mkdir -p "$root/.opencode/prompts"; [[ -f "$prompt" ]] || jq -r '.prompt // "Implement this task according to the task record."' <<<"$task" > "$prompt"
 "$SCRIPT_DIR/lease-manager.sh" acquire "$state" "$id" "$files" "$(jq -r '.lease_ttl_seconds // 3600' <<<"$task")" || break
 "$SCRIPT_DIR/worktree-manager.sh" create "$root" "$id" >/dev/null
 model="$(jq -r '.models.implementation' "$config")"; fallback="$(jq -r '.models.fallback' "$config")"; command=(opencode run --model "$model" "$(cat "$prompt")")
 "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "${command[@]}" >/dev/null || { model="$fallback"; command=(opencode run --model "$model" "$(cat "$prompt")"); "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "${command[@]}" >/dev/null || true; }
 tmp="$state.tmp.$$"; jq --arg id "$id" --arg model "$model" --arg wt "$wt" '.active += [{task_id:$id,status:"running",model:$model,worktree:$wt,started_at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"
 wsl_append_event "$state" task-started "$id" "$(jq -cn --arg model "$model" --arg worktree "$wt" '{model:$model,worktree:$worktree}')"; slots=$((slots-1))
done
