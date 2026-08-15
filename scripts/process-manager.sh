#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() { printf 'usage: %s start|stop|status <state> <task-id> [command...\n' "$0" >&2; exit 2; }

state_file="$2"
task_id="$3"
state_dir="$(dirname "$state_file")"
pid_file="$state_dir/processes/$task_id.json"
mkdir -p "$state_dir/processes" "$state_dir/logs"

case "${1:-}" in
  start)
    shift 3
    [[ $# -gt 0 ]] || usage
    log="$state_dir/logs/$task_id.log"
    setsid bash -lc 'exec "$@"' bash "$@" >>"$log" 2>&1 &
    pid=$!
    sleep 0.2
    pgid="$(ps -o pgid= -p "$pid" | tr -d ' ' || true)"
    [[ -n "$pgid" ]] || pgid="$pid"
    start_ticks="$(ps -o lstart= -p "$pid" | sed 's/^ *//' || true)"
    jq -cn --arg task_id "$task_id" --argjson pid "$pid" --arg pgid "$pgid" --arg start "$start_ticks" --arg log "$log" \
      '{task_id:$task_id,pid:$pid,pgid:$pgid,start_time:$start,log:$log,status:"running",started_at:(now|todateiso8601)}' > "$pid_file"
    printf '%s\n' "$pid"
    ;;
  stop)
    [[ -f "$pid_file" ]] || exit 0
    pid="$(jq -r '.pid' "$pid_file")"
    pgid="$(jq -r '.pgid' "$pid_file")"
    if [[ "$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true)" == "$(jq -r '.start_time' "$pid_file")" ]]; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
      deadline=$((SECONDS + ${TERM_GRACE_SECONDS:-15}))
      while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    jq '.status="stopped" | .stopped_at=(now|todateiso8601)' "$pid_file" > "$pid_file.tmp"
    mv "$pid_file.tmp" "$pid_file"
    ;;
  status)
    if [[ -f "$pid_file" ]]; then jq -c . "$pid_file"; else printf '{"status":"absent"}\n'; fi
    ;;
  *) usage ;;
esac
