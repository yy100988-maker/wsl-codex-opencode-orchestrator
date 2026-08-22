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

# --- V2.2: Adaptive concurrency from config ---
adaptive_concurrency() {
  local used="$1" max="$2" pressure_levels_json="$3" reduction_json="$4"
  local l1 l2 l3 l4 r1 r2 r3 r4
  l1=$(jq -r '.level1_percent' <<<"$pressure_levels_json")
  l2=$(jq -r '.level2_percent' <<<"$pressure_levels_json")
  l3=$(jq -r '.level3_percent' <<<"$pressure_levels_json")
  l4=$(jq -r '.level4_percent' <<<"$pressure_levels_json")
  r1=$(jq -r '.level1' <<<"$reduction_json")
  r2=$(jq -r '.level2' <<<"$reduction_json")
  r3=$(jq -r '.level3' <<<"$reduction_json")
  r4=$(jq -r '.level4' <<<"$reduction_json")
  if (( used < l1 )); then
    echo "$max"
  elif (( used < l2 )); then
    local c; c=$(awk "BEGIN{printf \"%d\", $max * $r1}"); (( c < 1 )) && c=1; echo "$c"
  elif (( used < l3 )); then
    local c; c=$(awk "BEGIN{printf \"%d\", $max * $r2}"); (( c < 1 )) && c=1; echo "$c"
  elif (( used < l4 )); then
    local c; c=$(awk "BEGIN{printf \"%d\", $max * $r3}"); (( c < 1 )) && c=1; echo "$c"
  else
    echo 0
  fi
}

# --- V2.2: Get memory pressure level ---
get_memory_pressure_level() {
  local used="$1" max_concurrent="$2" pressure_levels_json="$3" reduction_json="$4" cleanup_json="$5"
  local l1 l2 l3 l4 kill_count action level adaptive_c
  l1=$(jq -r '.level1_percent' <<<"$pressure_levels_json")
  l2=$(jq -r '.level2_percent' <<<"$pressure_levels_json")
  l3=$(jq -r '.level3_percent' <<<"$pressure_levels_json")
  l4=$(jq -r '.level4_percent' <<<"$pressure_levels_json")
  if (( used < l1 )); then
    level=0; action="none"
    adaptive_c="$max_concurrent"
    kill_count=0
  elif (( used < l2 )); then
    level=1; action="reduce"
    local r1; r1=$(jq -r '.level1' <<<"$reduction_json")
    adaptive_c=$(awk "BEGIN{c=int($max_concurrent * $r1); if(c<1)c=1; print c}")
    kill_count=0
  elif (( used < l3 )); then
    level=2; action="reduce"
    local r2; r2=$(jq -r '.level2' <<<"$reduction_json")
    adaptive_c=$(awk "BEGIN{c=int($max_concurrent * $r2); if(c<1)c=1; print c}")
    kill_count=0
  elif (( used < l4 )); then
    level=3; action="reduce-and-cleanup"
    local r3; r3=$(jq -r '.level3' <<<"$reduction_json")
    adaptive_c=$(awk "BEGIN{c=int($max_concurrent * $r3); if(c<1)c=1; print c}")
    kill_count=$(jq -r '.level3_kill_count // 1' <<<"$cleanup_json")
  else
    level=4; action="stop-and-cleanup"
    adaptive_c=0
    kill_count=$(jq -r '.level4_kill_count // 2' <<<"$cleanup_json")
  fi
  jq -cn --argjson level "$level" --argjson used "$used" --argjson adaptive_c "$adaptive_c" \
    --argjson kill_count "$kill_count" --arg action "$action" \
    '{level:$level,used_percent:$used,adaptive_concurrent:$adaptive_c,kill_count:$kill_count,action:$action}'
}

# --- V2.2: Level 3/4 memory pressure cleanup ---
invoke_memory_pressure_cleanup() {
  local config="$1" state="$2" root="$3" level="$4" kill_count="$5" dry_run="$6"
  (( kill_count > 0 )) || return 0
  local cleanup_json; cleanup_json=$(jq -c '.memory.memory_cleanup // {}' "$config")
  local managed_wt="$root/.opencode/worktrees"
  local now_epoch; now_epoch=$(date +%s)

  wsl_append_event "$state" memory_pressure_cleanup_started _ \
    "$(jq -cn --argjson level "$level" --argjson kill_count "$kill_count" --argjson dry_run "$dry_run" \
      '{level:$level,kill_count:$kill_count,dry_run:$dry_run}')"

  # Collect active running/admitted tasks with PID and RSS
  local candidates
  candidates=$(jq -c --arg managed "$managed_wt" '
    [.active[] | select(.status == "running" or .status == "admitted")] |
    map(select(.worktree != null and (.worktree | startswith($managed)))) |
    sort_by(.task_id)
  ' "$state")

  local count; count=$(jq 'length' <<<"$candidates")
  (( count > 0 )) || { wsl_append_event "$state" memory_pressure_cleanup_completed _ \
    "$(jq -cn --argjson level "$level" '{level:$level,killed:0}')"; return 0; }

  # Enrich with peak_rss_mb from /proc/<pid>/status
  local enriched="[]"
  local i=0
  while (( i < count )); do
    local entry; entry=$(jq -c ".[$i]" <<<"$candidates")
    local tid; tid=$(jq -r '.task_id' <<<"$entry")
    local pid_file="$root/.opencode/processes/$tid.json"
    if [[ -f "$pid_file" ]]; then
      local pid; pid=$(jq -r '.pid // empty' <<<"$pid_file" 2>/dev/null || true)
      local proc_pid; proc_pid=$(jq -r '.pid // empty' <<<"$(cat "$pid_file")" 2>/dev/null || true)
      local peak_rss=0
      if [[ -n "$proc_pid" && -d "/proc/$proc_pid" ]]; then
        peak_rss=$(awk '/VmRSS/ {print $2}' "/proc/$proc_pid/status" 2>/dev/null || echo 0)
      fi
      enriched=$(jq --argjson entry "$entry" --argjson rss "$peak_rss" '. + [$entry | . + {peak_rss_mb:($rss/1024), pid_file:"'$pid_file'"}]' <<<"$enriched")
    fi
    i=$((i + 1))
  done

  # Sort by peak_rss_mb descending, take top kill_count
  local sorted; sorted=$(jq -c --argjson k "$kill_count" 'sort_by(-.peak_rss_mb) | .[:$k]' <<<"$enriched")
  local victims_count; victims_count=$(jq 'length' <<<"$sorted")

  i=0
  while (( i < victims_count )); do
    local victim; victim=$(jq -c ".[$i]" <<<"$sorted")
    local tid; tid=$(jq -r '.task_id' <<<"$victim")
    local wt; wt=$(jq -r '.worktree' <<<"$victim")
    local pid_file; pid_file=$(jq -r '.pid_file // ""' <<<"$victim")
    local peak_rss; peak_rss=$(jq -r '.peak_rss_mb // 0' <<<"$victim")

    if [[ "$dry_run" == "true" ]]; then
      wsl_append_event "$state" memory_cleanup_kill "$tid" \
        "$(jq -cn --argjson level "$level" --arg reason "dry-run" --argjson peak "$peak_rss" \
          '{level:$level,reason:$reason,peak_rss_mb:$peak}')"
    else
      # Validate PID/PGID from process file before killing
      if [[ -n "$pid_file" && -f "$pid_file" ]]; then
        local proc_pid proc_pgid start_time
        proc_pid=$(jq -r '.pid' "$pid_file")
        proc_pgid=$(jq -r '.pgid' "$pid_file")
        start_time=$(jq -r '.start_time' "$pid_file")
        if [[ -n "$proc_pid" && -d "/proc/$proc_pid" ]]; then
          local live_start; live_start=$(ps -o lstart= -p "$proc_pid" 2>/dev/null | sed 's/^ *//' || true)
          if [[ "$live_start" == "$start_time" ]]; then
            kill -TERM -- "-$proc_pgid" 2>/dev/null || true
            sleep 2
            kill -KILL -- "-$proc_pgid" 2>/dev/null || true
          fi
        fi
        jq '.status="stopped" | .stopped_at=(now|todateiso8601)' "$pid_file" > "$pid_file.tmp"
        mv "$pid_file.tmp" "$pid_file"
      fi

      "$SCRIPT_DIR/process-manager.sh" stop "$state" "$tid" 2>/dev/null || true
      "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$tid" 2>/dev/null || true
      "$SCRIPT_DIR/lease-manager.sh" release "$state" "$tid" 2>/dev/null || true
      wsl_remove_active_task "$state" "$tid"
      wsl_update_task_status "$tasks" "$tid" blocked "memory-pressure-cleanup"

      wsl_append_event "$state" memory_cleanup_kill "$tid" \
        "$(jq -cn --argjson level "$level" --arg reason "killed" --argjson peak "$peak_rss" \
          '{level:$level,reason:$reason,peak_rss_mb:$peak}')"
    fi
    i=$((i + 1))
  done

  wsl_append_event "$state" memory_pressure_cleanup_completed _ \
    "$(jq -cn --argjson level "$level" --argjson killed "$victims_count" '{level:$level,killed:$killed}')"
}

# --- Resolve config values ---
max="$(jq -r '.scheduler.max_concurrent_agents // 5' "$config")"
pressure_levels_json=$(jq -c '.memory.pressure_levels // {level1_percent:70,level2_percent:80,level3_percent:85,level4_percent:90}' "$config")
reduction_json=$(jq -c '.memory.concurrency_reduction // {level1:0.7,level2:0.4,level3:0.1,level4:0}' "$config")
cleanup_json=$(jq -c '.memory.memory_cleanup // {level3_kill_count:1,level4_kill_count:2,dry_run:false}' "$config")

active="$(jq '[.active[] | select(.status=="running" or .status=="admitted")] | length' "$state")"

# Get WSL memory usage
wsl_used=$(free | awk '/Mem:/ {printf "%.0f", (($2-$7)/$2)*100}')
wsl_stop="$(jq -r '.memory.wsl_stop_admission_percent // 88' "$config")"
wsl_critical="$(jq -r '.memory.wsl_critical_percent // 90' "$config")"

# --- Host memory check ---
stop="$(jq -r '.memory.windows_stop_admission_percent // 88' "$config")"; critical="$(jq -r '.memory.windows_critical_percent // 90' "$config")"; reserve="$(jq -r '.memory.windows_reserve_mb // 4096' "$config")"
host_script_win="$(wslpath -w "$SCRIPT_DIR/host-memory-guard.ps1")"
host_output="$(powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$host_script_win" -StopAdmissionPercent "$stop" -CriticalPercent "$critical" -ReserveMB "$reserve" 2>&1 | tr -d '\r')" || { wsl_append_event "$state" admission-error _ "$(jq -cn --arg output "$host_output" '{reason:"host-memory-command-failed",output:$output}')"; exit 1; }
host_json="$(printf '%s\n' "$host_output" | sed -n '/{.*}/p' | tail -n 1)"; jq -e . >/dev/null <<<"$host_json" || { wsl_append_event "$state" admission-error _ "$(jq -cn --arg output "$host_output" '{reason:"host-memory-invalid-json",output:$output}')"; exit 1; }
host_epoch="$(date -d "$(jq -r '.measured_at' <<<"$host_json")" +%s 2>/dev/null || echo 0)"; wsl_epoch="$(date +%s)"; skew=$((wsl_epoch-host_epoch)); (( skew < 0 )) && skew=$((-skew))
(( skew <= 300 )) || { wsl_append_event "$state" admission-error _ "$(jq -cn --argjson skew "$skew" '{reason:"clock-skew-too-large",seconds:$skew}')"; exit 1; }
if [[ "$(jq -r '.admission_allowed' <<<"$host_json")" != true ]]; then wsl_append_event "$state" admission-paused _ "$host_json"; exit 0; fi

# --- V2.2: Scheduling pressure = max(wsl, host) ---
host_used=$(jq -r '.host_used_percent | floor' <<<"$host_json")
max_used=$(( wsl_used > host_used ? wsl_used : host_used ))

used="$max_used"
metrics="$(jq -cn --argjson wsl "$wsl_used" --argjson host "$host_used" --argjson max_used "$used" --argjson available "$(jq -r '.available_mb' <<<"$host_json")" --arg active "$active" '{wsl_used_percent:$wsl,host_used_percent:$host,used_percent:$max_used,host_available_mb:$available,active:($active|tonumber),sampled_at:(now|todateiso8601)}')"
printf '%s\n' "$metrics" >> "$root/.opencode/metrics/memory.jsonl"

# --- V2.2: Pressure level evaluation ---
pressure_info=$(get_memory_pressure_level "$used" "$max" "$pressure_levels_json" "$reduction_json" "$cleanup_json")
pressure_level=$(jq -r '.level' <<<"$pressure_info")
pressure_action=$(jq -r '.action' <<<"$pressure_info")
effective_max=$(jq -r '.adaptive_concurrent' <<<"$pressure_info")
kill_count=$(jq -r '.kill_count' <<<"$pressure_info")

# Stop admission at Level 4
if [[ "$pressure_action" == "stop-and-cleanup" ]]; then
  wsl_append_event "$state" admission-paused _ "$(jq -cn --argjson info "$pressure_info" '$info + {reason:"memory-pressure-level4-stop"}')"
fi

# Level 3/4 cleanup
if [[ "$pressure_level" -ge 3 ]]; then
  dry_run=$(jq -r '.memory.memory_cleanup.dry_run // false' <<<"$(jq -c . "$config")")
  invoke_memory_pressure_cleanup "$config" "$state" "$root" "$pressure_level" "$kill_count" "$dry_run"
fi

# Legacy WSL stop admission check (kept for backward compat)
if (( used >= wsl_stop )); then wsl_append_event "$state" admission-paused _ "$(jq -cn --argjson used "$used" --argjson critical "$wsl_critical" '{wsl_used_percent:$used,critical:($used >= $critical),reason:"wsl-memory-stop-admission"}')"; exit 0; fi

slots=$((effective_max-active)); (( slots > 0 )) || exit 0

done_ids="$(jq -c '[.history[] | select(.status == "done") | .task_id]' "$state")"; active_ids="$(jq -c '[.active[] | .task_id]' "$state")"
candidates="$(jq -c --argjson done "$done_ids" --argjson active "$active_ids" '[.tasks[] | select((.status // "pending") == "pending" or (.status // "pending") == "waiting") | select((.id as $id | ($active | index($id))) == null) | select(all((.depends_on // [])[]; . as $dep | ($done | index($dep)) != null))]' "$tasks")"

while IFS= read -r task && (( slots > 0 )); do
  [[ -n "$task" ]] || continue
  id="$(jq -r '.id' <<<"$task")"; wt="$root/.opencode/worktrees/$id"; prompt="$root/.opencode/prompts/$id.md"; files="$(jq -c '.allowed_files // []' <<<"$task")"
  base_commit="$(jq -r '.base_commit // empty' <<<"$task")"
  if [[ -z "$base_commit" ]]; then
    base_commit="$(git -C "$root" rev-parse HEAD)"
    tmp_tasks="$tasks.tmp.$$"
    jq --arg id "$id" --arg base "$base_commit" '(.tasks[] | select(.id == $id) | .base_commit) = $base' "$tasks" > "$tmp_tasks"
    mv "$tmp_tasks" "$tasks"
    task="$(jq -c --arg id "$id" 'first(.tasks[] | select(.id == $id))' "$tasks")"
  fi
  mkdir -p "$root/.opencode/prompts"
  [[ -f "$prompt" ]] || jq -r '.prompt // .design_slice // "Implement this task according to the task record."' <<<"$task" > "$prompt"
  "$SCRIPT_DIR/lease-manager.sh" acquire "$state" "$id" "$files" "$(jq -r '.lease_ttl_seconds // 3600' <<<"$task")" || continue
  if ! "$SCRIPT_DIR/worktree-manager.sh" create "$root" "$id" >/dev/null; then
    "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; wsl_append_event "$state" task-blocked "$id" '{"reason":"worktree-create-failed"}'; continue
  fi
  rm -f "$wt/.opencode-handoff.json" "$wt/.opencode-task-prompt.md"
  cp "$prompt" "$wt/.opencode-task-prompt.md"
  model="$(jq -r '.models.implementation' "$config")"; fallback="$(jq -r '.models.fallback' "$config")"; last_resort="$(jq -r '.models.last_resort // ""' "$config")"; started=false
  task_msg="$(cat "$wt/.opencode-task-prompt.md")"
  command=(opencode run --model "$model" --message "$task_msg")
  if "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "$wt" "${command[@]}" >/dev/null; then started=true; else
    wsl_append_event "$state" model-fallback "$id" "$(jq -cn --arg from "$model" --arg to "$fallback" '{from:$from,to:$to,reason:"primary-start-failed"}')"; model="$fallback"; command=(opencode run --model "$model" --message "$task_msg")
    if "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "$wt" "${command[@]}" >/dev/null; then
      started=true
    elif [[ -n "$last_resort" ]]; then
      wsl_append_event "$state" model-fallback "$id" "$(jq -cn --arg from "$model" --arg to "$last_resort" '{from:$from,to:$to,reason:"fallback-start-failed"}')"; model="$last_resort"; command=(opencode run --model "$model" --message "$task_msg")
      "$SCRIPT_DIR/process-manager.sh" start "$state" "$id" "$wt" "${command[@]}" >/dev/null && started=true || true
    fi
  fi
  if [[ "$started" != true ]]; then
    "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true; "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; wsl_update_task_status "$tasks" "$id" blocked "opencode-start-failed"; wsl_append_event "$state" task-blocked "$id" '{"reason":"opencode-start-failed"}'; continue
  fi
  tmp="$state.tmp.$$"; jq --arg id "$id" --arg model "$model" --arg wt "$wt" '.active += [{task_id:$id,status:"running",model:$model,worktree:$wt,started_at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"
  wsl_update_task_status "$tasks" "$id" running
  wsl_append_event "$state" task-started "$id" "$(jq -cn --arg model "$model" --arg worktree "$wt" '{model:$model,worktree:$worktree}')"; slots=$((slots-1))
done < <(jq -c '.[]' <<<"$candidates")
