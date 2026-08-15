#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config}"; root="$(jq -r '.wsl.project_root' "$config")"; state="$root/.opencode/orchestrator-state.json"; tasks="$root/.opencode/tasks.json"
[[ -f "$tasks" ]] || wsl_die "tasks manifest not found: $tasks"
wsl_ensure_state_dirs "$state"
exec 8>"$state.lock"; flock -n 8 || exit 75
"$SCRIPT_DIR/lease-manager.sh" purge "$state" _ >/dev/null
jq -e 'type == "object" and (.active | type == "array") and (.history | type == "array")' "$state" >/dev/null || wsl_die "invalid orchestrator state schema: $state"
jq -e 'type == "object" and (.tasks | type == "array") and all(.tasks[]; (.id | type == "string"))' "$tasks" >/dev/null || wsl_die "invalid tasks manifest schema: $tasks"
wsl_reconcile_task_manifest "$tasks" "$state"
max="$(jq -r '.scheduler.max_concurrent_agents // 100' "$config")"
active="$(jq '[.active[] | select(.status=="running" or .status=="admitted")] | length' "$state")"
slots=$((max-active)); (( slots > 0 )) || exit 0

stop="$(jq -r '.memory.windows_stop_admission_percent // 88' "$config")"; critical="$(jq -r '.memory.windows_critical_percent // 90' "$config")"; reserve="$(jq -r '.memory.windows_reserve_mb // 4096' "$config")"
host_script_win="$(wslpath -w "$SCRIPT_DIR/host-memory-guard.ps1")"
host_output="$(powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$host_script_win" -StopAdmissionPercent "$stop" -CriticalPercent "$critical" -ReserveMB "$reserve" 2>&1 | tr -d '\r')" || { wsl_append_event "$state" admission-error _ "$(jq -cn --arg output "$host_output" '{reason:"host-memory-command-failed",output:$output}')"; exit 1; }
host_json="$(printf '%s\n' "$host_output" | sed -n '/{.*}/p' | tail -n 1)"; jq -e . >/dev/null <<<"$host_json" || { wsl_append_event "$state" admission-error _ "$(jq -cn --arg output "$host_output" '{reason:"host-memory-invalid-json",output:$output}')"; exit 1; }
host_epoch="$(date -d "$(jq -r '.measured_at' <<<"$host_json")" +%s 2>/dev/null || echo 0)"; wsl_epoch="$(date +%s)"; skew=$((wsl_epoch-host_epoch)); (( skew < 0 )) && skew=$((-skew))
(( skew <= 300 )) || { wsl_append_event "$state" admission-error _ "$(jq -cn --argjson skew "$skew" '{reason:"clock-skew-too-large",seconds:$skew}')"; exit 1; }
if [[ "$(jq -r '.admission_allowed' <<<"$host_json")" != true ]]; then wsl_append_event "$state" admission-paused _ "$host_json"; exit 0; fi

used="$(free | awk '/Mem:/ {printf "%.0f", (($2-$7)/$2)*100}')"; wsl_stop="$(jq -r '.memory.wsl_stop_admission_percent // 88' "$config")"; wsl_critical="$(jq -r '.memory.wsl_critical_percent // 90' "$config")"
metrics="$(jq -cn --argjson wsl "$used" --argjson host "$(jq -r '.host_used_percent' <<<"$host_json")" --argjson available "$(jq -r '.available_mb' <<<"$host_json")" --arg active "$active" '{wsl_used_percent:$wsl,host_used_percent:$host,host_available_mb:$available,active:($active|tonumber),sampled_at:(now|todateiso8601)}')"
printf '%s\n' "$metrics" >> "$root/.opencode/metrics/memory.jsonl"
if (( used >= wsl_stop )); then wsl_append_event "$state" admission-paused _ "$(jq -cn --argjson used "$used" --argjson critical "$wsl_critical" '{wsl_used_percent:$used,critical:($used >= $critical),reason:"wsl-memory-stop-admission"}')"; exit 0; fi

done_ids="$(jq -c '[.history[] | select(.status == "done") | .task_id]' "$state")"; active_ids="$(jq -c '[.active[] | .task_id]' "$state")"
candidates="$(jq -c --argjson done "$done_ids" --argjson active "$active_ids" '[.tasks[] | select((.status // "pending") == "pending" or (.status // "pending") == "waiting") | select((.id as $id | ($active | index($id))) == null) | select(all((.depends_on // [])[]; . as $dep | ($done | index($dep)) != null))]' "$tasks")"

while IFS= read -r task && (( slots > 0 )); do
  [[ -n "$task" ]] || continue
  id="$(jq -r '.id' <<<"$task")"; wt="$root/.opencode/worktrees/$id"; prompt="$root/.opencode/prompts/$id.md"; files="$(jq -c '.allowed_files // []' <<<"$task")"
  mkdir -p "$root/.opencode/prompts"
  [[ -f "$prompt" ]] || jq -r '.prompt // .design_slice // "Implement this task according to the task record."' <<<"$task" > "$prompt"
  "$SCRIPT_DIR/lease-manager.sh" acquire "$state" "$id" "$files" "$(jq -r '.lease_ttl_seconds // 3600' <<<"$task")" || continue
  if ! "$SCRIPT_DIR/worktree-manager.sh" create "$root" "$id" >/dev/null; then
    "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; wsl_append_event "$state" task-blocked "$id" '{"reason":"worktree-create-failed"}'; continue
  fi
  rm -f "$wt/.opencode-handoff.json" "$wt/.opencode-task-prompt.md"
  cp "$prompt" "$wt/.opencode-task-prompt.md"
  model="$(jq -r '.models.implementation' "$config")"; fallback="$(jq -r '.models.fallback' "$config")"; started=false
  command=(opencode run --model "$model" "Read the attached task prompt and implement only this task.")
  if "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "$wt" "${command[@]}" >/dev/null; then started=true; else
    wsl_append_event "$state" model-fallback "$id" "$(jq -cn --arg from "$model" --arg to "$fallback" '{from:$from,to:$to,reason:"primary-start-failed"}')"; model="$fallback"; command=(opencode run --model "$model" "Read the attached task prompt and implement only this task.")
    "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "$wt" "${command[@]}" >/dev/null && started=true || true
  fi
  if [[ "$started" != true ]]; then
    "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true; "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; wsl_update_task_status "$tasks" "$id" blocked "opencode-start-failed"; wsl_append_event "$state" task-blocked "$id" '{"reason":"opencode-start-failed"}'; continue
  fi
  tmp="$state.tmp.$$"; jq --arg id "$id" --arg model "$model" --arg wt "$wt" '.active += [{task_id:$id,status:"running",model:$model,worktree:$wt,started_at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"
  wsl_update_task_status "$tasks" "$id" running
  wsl_append_event "$state" task-started "$id" "$(jq -cn --arg model "$model" --arg worktree "$wt" '{model:$model,worktree:$worktree}')"; slots=$((slots-1))
done < <(jq -c '.[]' <<<"$candidates")
