#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config}"; root="$(jq -r '.wsl.project_root' "$config")"; state="$root/.opencode/orchestrator-state.json"; interval="$(jq -r '.scheduler.monitor_interval_seconds // 60' "$config")"
mkdir -p "$root/.opencode"; exec 9>"$root/.opencode/supervisor.lock"; flock -n 9 || wsl_die "supervisor already running"
trap 'exit 0' INT TERM
"$SCRIPT_DIR/ensure-dependencies.sh"
"$SCRIPT_DIR/preflight.sh" "$config" || exit $?
while :; do
  "$SCRIPT_DIR/admission-cycle.sh" "$config" || true
  for record in "$root"/.opencode/processes/*.json; do
    [[ -f "$record" ]] || continue
    [[ "$(jq -r '.status // "running"' "$record")" == "running" ]] || continue
    id="$(jq -r '.task_id' "$record")"; pid="$(jq -r '.pid' "$record")"; kill -0 "$pid" 2>/dev/null && continue
    wt="$root/.opencode/worktrees/$id"; "$SCRIPT_DIR/gate-runner.sh" "$root" "$id" "$wt" >/dev/null || true
    passed="$(jq -r '.passed' "$root/.opencode/gates/$id/result.json" 2>/dev/null || echo false)"
    "$SCRIPT_DIR/process-manager.sh" stop "$state" "$id" >/dev/null || true
    if [[ "$passed" == true ]]; then git -C "$root" merge --no-edit "codex/task-$id" >/dev/null 2>&1 || true; "$SCRIPT_DIR/worktree-manager.sh" remove "$root" "$id"; status=done; else "$SCRIPT_DIR/worktree-manager.sh" archive "$root" "$id"; status=blocked; fi
    "$SCRIPT_DIR/lease-manager.sh" release "$state" "$id"; tmp="$state.tmp.$$"; jq --arg id "$id" --arg status "$status" '(.active |= map(select(.task_id != $id))) | .history += [{task_id:$id,status:$status,at:(now|todateiso8601)}]' "$state" > "$tmp"; mv "$tmp" "$state"; wsl_append_event "$state" task-finished "$id" "$(jq -cn --arg status "$status" '{status:$status}')"
  done
  sleep "$interval"
done
