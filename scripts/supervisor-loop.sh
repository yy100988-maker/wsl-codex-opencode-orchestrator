#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config}"
resolved_config="$("$SCRIPT_DIR/read-config.sh" "$config")"
root="$(jq -r '.wsl.project_root' "$resolved_config")"; state="$root/.opencode/orchestrator-state.json"; tasks="$root/.opencode/tasks.json"; interval="$(jq -r '.scheduler.monitor_interval_seconds // 30' "$resolved_config")"
orphan_scan_interval="$(jq -r '.scheduler.orphan_scan_interval // 5' "$resolved_config")"
disk_recovery_interval="$(jq -r '.scheduler.disk_recovery_interval // 10' "$resolved_config")"
event_compress_interval="$(jq -r '.scheduler.event_compress_interval // 100' "$resolved_config")"
max_runtime="$(jq -r '.scheduler.max_task_runtime_seconds // 3600' "$resolved_config")"
stall_timeout="$(jq -r '.scheduler.stall_timeout_seconds // 300' "$resolved_config")"
health_stall_timeout="$(jq -r '.scheduler.health_stall_timeout_seconds // 600' "$resolved_config")"
health_warning_persist_threshold="$(jq -r '.scheduler.health_warning_persist_threshold // 2' "$resolved_config")"
mkdir -p "$root/.opencode"; exec 9>"$root/.opencode/supervisor.lock"; flock -n 9 || wsl_die "supervisor already running"
trap 'exit 0' INT TERM
"$SCRIPT_DIR/ensure-dependencies.sh"
"$SCRIPT_DIR/ensure-opencode.sh" "$config"
"$SCRIPT_DIR/runtime-preflight.sh" "$(jq -r '.wsl.project_root' "$resolved_config")" "$resolved_config"
"$SCRIPT_DIR/preflight.sh" "$resolved_config"
# Orphan process scanner (V2.2: fixed JSON, config param, last_orphan_scan_at)
invoke_orphan_process_scan() {
  local state="$1" root="$2" config="$3"
  for record in "$root"/.opencode/processes/*.json; do
    [[ -f "$record" ]] || continue
    [[ "$(jq -r '.status // "running"' "$record")" == "running" ]] || continue
    local id=$(jq -r '.task_id' "$record")
    local pid=$(jq -r '.pid' "$record")
    if kill -0 "$pid" 2>/dev/null; then continue; fi
    # Root dead, find orphaned children by worktree path
    local wt=$(jq -r '.cwd // empty' "$record")
    if [[ -n "$wt" ]]; then
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      if [[ -n "$pgid" ]]; then
        ps -o pid= --pgid "$pgid" 2>/dev/null | while read -r child_pid; do
          child_pid=$(echo "$child_pid" | tr -d ' ')
          [[ -n "$child_pid" ]] || continue
          kill -TERM "$child_pid" 2>/dev/null || true
          wsl_append_event "$state" orphan-killed "$id" "$(jq -cn --argjson pid "$child_pid" '{pid:$pid}')"
        done
      fi
    fi
    "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
    wsl_append_event "$state" orphan-recovered "$id" '{"reason":"root-process-dead"}'
  done
  tmp="$state.tmp.$$"; jq --arg ts "$(wsl_now)" '.last_orphan_scan_at = $ts' "$state" > "$tmp"; mv "$tmp" "$state"
}
# Health monitoring (V2.2: per-cycle snapshot, dead/stall/warning actions)
get_process_health_state() {
  local health_json="$1"
  local status
  status="$(jq -r '.status' "$health_json")"
  local log_age
  log_age="$(jq -r '.log_age_minutes' "$health_json")"
  local stall_timeout_min
  stall_timeout_min="$(awk "BEGIN {printf \"%.1f\", $health_stall_timeout / 60.0}")"
  if [[ "$status" == "dead" ]]; then
    echo "dead"
  elif awk "BEGIN {exit !(${log_age} > ${stall_timeout_min})}" 2>/dev/null; then
    echo "stall"
  else
    echo "alive"
  fi
}
monitor_health() {
  local state="$1" root="$2" health_warn_threshold="$3"
  for record in "$root"/.opencode/processes/*.json; do
    [[ -f "$record" ]] || continue
    [[ "$(jq -r '.status // "running"' "$record")" == "running" ]] || continue
    local id
    id="$(jq -r '.task_id' "$record")"
    local health_json
    health_json="$("$SCRIPT_DIR/process-manager.sh" health "$state" "$id" 2>/dev/null || true)"
    [[ -n "$health_json" ]] || continue
    # Append to metrics/health.jsonl
    local metrics_file="$root/.opencode/metrics/health.jsonl"
    mkdir -p "$root/.opencode/metrics"
    printf '%s\n' "$health_json" >> "$metrics_file"
    # Evaluate health state
    local hstate
    hstate="$(get_process_health_state "$health_json")"
    if [[ "$hstate" == "dead" ]]; then
      wsl_append_event "$state" process_dead "$id" '{"reason":"process-exit"}'
      "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
      "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true
      "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"
      wsl_remove_active_task "$state" "$id"
      wsl_update_task_status "$tasks" "$id" blocked "process-dead"
      tmp="$state.tmp.$$"; jq --arg id "$id" '.history += [{task_id:$id,status:"blocked",reason:"process-dead",at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"
    elif [[ "$hstate" == "stall" ]]; then
      wsl_append_event "$state" process_stall "$id" '{"reason":"no-output"}'
    elif [[ "$hstate" == "warning" ]]; then
      wsl_append_event "$state" health_warning "$id" '{"reason":"warning-detected"}'
    fi
  done
}

cycle_count=0
last_orphan_scan_at=""
last_disk_recovery_cycle=0
last_event_compress_cycle=0
# Startup: initial event compress
if jq -e '.event_compress.enabled // true' <<< "$resolved_config" >/dev/null 2>&1; then
  "$SCRIPT_DIR/event-store.sh" "$root" "$config" 2>/dev/null || true
fi
mkdir -p "$root/.opencode/metrics"
while :; do
  cycle_count=$((cycle_count + 1))
  # Periodic event compression
  if (( cycle_count % event_compress_interval == 0 )); then
    if jq -e '.event_compress.enabled // true' <<< "$resolved_config" >/dev/null 2>&1; then
      "$SCRIPT_DIR/event-store.sh" "$root" "$config" 2>/dev/null || true
    fi
  fi
  # Periodic orphan scan
  if (( cycle_count % orphan_scan_interval == 0 )); then
    invoke_orphan_process_scan "$state" "$root" "$resolved_config" 2>/dev/null || true
  fi
  if ! "$SCRIPT_DIR/admission-cycle.sh" "$resolved_config"; then
    wsl_append_event "$state" supervisor-error _ '{"reason":"admission-cycle-failed"}'
    exit 1
  fi
  exec 8>"$state.lock"; flock -x 8
  now_epoch="$(date +%s)"
  for record in "$root"/.opencode/processes/*.json; do
    [[ -f "$record" ]] || continue
    [[ "$(jq -r '.status // "running"' "$record")" == "running" ]] || continue
    id="$(jq -r '.task_id' "$record")"; pid="$(jq -r '.pid' "$record")"
    if kill -0 "$pid" 2>/dev/null; then
      started_epoch="$(date -d "$(jq -r '.started_at' "$record")" +%s 2>/dev/null || echo 0)"; log_path="$(jq -r '.log // empty' "$record")"; log_epoch="$(stat -c %Y "$log_path" 2>/dev/null || echo "$started_epoch")"
      timed_out=false; [[ "$max_runtime" -gt 0 && "$started_epoch" -gt 0 && $((now_epoch-started_epoch)) -ge "$max_runtime" ]] && timed_out=true
      stalled=false; [[ "$stall_timeout" -gt 0 && $((now_epoch-log_epoch)) -ge "$stall_timeout" ]] && stalled=true
      if [[ "$timed_out" == true || "$stalled" == true ]]; then
        reason="$(if [[ "$timed_out" == true ]]; then printf 'max-runtime-exceeded'; else printf 'stall-timeout'; fi)"
        "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true; "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true; "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; wsl_remove_active_task "$state" "$id"; wsl_update_task_status "$tasks" "$id" blocked "$reason"; tmp="$state.tmp.$$"; jq --arg id "$id" --arg reason "$reason" '.history += [{task_id:$id,status:"blocked",reason:$reason,at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"; wsl_append_event "$state" task-timeout "$id" "$(jq -cn --arg reason "$reason" '{reason:$reason}')"; continue
      fi
      continue
    fi
    wt="$root/.opencode/worktrees/$id"
    gate_passed=false
    if "$SCRIPT_DIR/gate-runner.sh" "$root" "$id" "$wt" >/dev/null 2>&1; then gate_passed=true; fi
    gate_file="$root/.opencode/gates/$id/result.json"
    if [[ "$gate_passed" == true ]]; then
      task_base="$(jq -r --arg id "$id" 'first(.tasks[] | select(.id == $id) | .base_commit) // empty' "$tasks")"
      branch="codex/task-$id"
      branch_commit="$(git -C "$root" rev-parse "$branch" 2>/dev/null || true)"
      branch_changes="$(git -C "$root" diff --name-only "$task_base" "$branch_commit" 2>/dev/null || true)"
      if [[ -z "$task_base" || -z "$branch_commit" || "$branch_commit" == "$task_base" || -z "$branch_changes" ]]; then
        status=blocked; reason="empty-task-branch"; wsl_append_event "$state" merge-error "$id" '{"reason":"empty-task-branch"}'
        "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true
        "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
      elif git -C "$root" merge --no-edit "$branch" >/dev/null 2>&1; then
        merged_commit="$(git -C "$root" rev-parse HEAD)"
        expected_files="$(jq -c '.changed_files // []' "$gate_file")"
        merged_files="$(git -C "$root" diff --name-only "$task_base" "$merged_commit" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
        if ! jq -e --argjson expected "$expected_files" --argjson actual "$merged_files" 'all($expected[]; . as $file | ($actual | index($file)) != null)' >/dev/null <<< '{}'; then
          status=blocked; reason="merge-content-verification-failed"; git -C "$root" merge --abort >/dev/null 2>&1 || true
          wsl_append_event "$state" merge-error "$id" '{"reason":"merge-content-verification-failed"}'
          "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true
          "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
        elif ! "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || ! "$SCRIPT_DIR/worktree-manager.sh" remove "$root" "$id"; then
          wsl_append_event "$state" cleanup-error "$id" '{"reason":"accepted-task-cleanup-failed"}'; continue
        else
          status=done; reason="gate-passed"; wsl_append_event "$state" task-merged "$id" "$(jq -cn --arg commit "$merged_commit" '{merged_commit:$commit}')"
        fi
      else
        status=blocked; reason="merge-failed"; wsl_append_event "$state" merge-error "$id" '{"reason":"git-merge-failed"}'
        git -C "$root" merge --abort >/dev/null 2>&1 || true
        "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true
        "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
      fi
    else
      status=blocked; reason="gate-failed"; "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true; "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id" || true
    fi
    "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"
    wsl_remove_active_task "$state" "$id"
    wsl_update_task_status "$tasks" "$id" "$status" "$reason"
    tmp="$state.tmp.$$"; jq --arg id "$id" --arg status "$status" --arg reason "$reason" '.history += [{task_id:$id,status:$status,reason:$reason,gate:(input_filename),at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"
    wsl_append_event "$state" task-finished "$id" "$(jq -cn --arg status "$status" --arg reason "$reason" --arg gate "$gate_file" '{status:$status,reason:$reason,gate:$gate}')"
  done
  exec 8>&-
  # Health monitoring (every cycle)
  monitor_health "$state" "$root" "$health_warning_persist_threshold" 2>/dev/null || true
  # Periodic disk recovery
  if (( cycle_count % disk_recovery_interval == 0 )); then
    "$SCRIPT_DIR/worktree-manager.sh" disk-recovery "$root" "$config" 2>/dev/null || true
  fi
  sleep "$interval"
done
