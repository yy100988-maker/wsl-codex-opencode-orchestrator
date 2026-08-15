#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config}"; root="$(jq -r '.wsl.project_root' "$config")"; state="$root/.opencode/orchestrator-state.json"; tasks="$root/.opencode/tasks.json"; interval="$(jq -r '.scheduler.monitor_interval_seconds // 30' "$config")"
mkdir -p "$root/.opencode"; exec 9>"$root/.opencode/supervisor.lock"; flock -n 9 || wsl_die "supervisor already running"
trap 'exit 0' INT TERM
"$SCRIPT_DIR/ensure-dependencies.sh"
"$SCRIPT_DIR/preflight.sh" "$config"
while :; do
  if ! "$SCRIPT_DIR/admission-cycle.sh" "$config"; then
    wsl_append_event "$state" supervisor-error _ '{"reason":"admission-cycle-failed"}'
    exit 1
  fi
  exec 8>"$state.lock"; flock -x 8
  max_runtime="$(jq -r '.scheduler.max_task_runtime_seconds // 0' "$config")"; stall_timeout="$(jq -r '.scheduler.stall_timeout_seconds // 0' "$config")"; now_epoch="$(date +%s)"
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
      if git -C "$root" merge --no-edit "codex/task-$id" >/dev/null 2>&1; then
        if ! "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || ! "$SCRIPT_DIR/worktree-manager.sh" remove "$root" "$id"; then
          wsl_append_event "$state" cleanup-error "$id" '{"reason":"accepted-task-cleanup-failed"}'; continue
        fi
        status=done; reason="gate-passed"
      else
        status=blocked; reason="merge-failed"; wsl_append_event "$state" merge-error "$id" '{"reason":"git-merge-failed"}'
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
  sleep "$interval"
done
