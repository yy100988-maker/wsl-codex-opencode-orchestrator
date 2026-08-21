#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() { printf 'usage: %s start <state> <task-id> <cwd> <command...> | stop|status|health <state> <task-id>\n' "$0" >&2; exit 2; }

state_file="$2"
task_id="$3"
state_dir="$(dirname "$state_file")"
pid_file="$state_dir/processes/$task_id.json"
mkdir -p "$state_dir/processes" "$state_dir/logs"

case "${1:-}" in
  start)
    cwd="${4:-}"
    shift 4
    [[ -d "$cwd" ]] || wsl_die "working directory not found: $cwd"
    [[ $# -gt 0 ]] || usage
    log="$state_dir/logs/$task_id.log"
    setsid bash -lc 'cd "$1" && shift && exec "$@"' bash "$cwd" "$@" >>"$log" 2>&1 &
    pid=$!
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { printf 'process exited during startup; see %s\n' "$log" >&2; exit 4; }
    pgid="$(ps -o pgid= -p "$pid" | tr -d ' ' || true)"
    [[ -n "$pgid" ]] || pgid="$pid"
    start_ticks="$(ps -o lstart= -p "$pid" | sed 's/^ *//' || true)"
    jq -cn --arg task_id "$task_id" --argjson pid "$pid" --arg pgid "$pgid" --arg start "$start_ticks" --arg cwd "$cwd" --arg log "$log" \
      '{task_id:$task_id,pid:$pid,pgid:$pgid,start_time:$start,cwd:$cwd,log:$log,status:"running",started_at:(now|todateiso8601)}' > "$pid_file"
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
  health)
    [[ -f "$pid_file" ]] || wsl_die "no process record for task $task_id"
    pid="$(jq -r '.pid' "$pid_file")"
    log_path="$(jq -r '.log // ""' "$pid_file")"
    cwd="$(jq -r '.cwd // ""' "$pid_file")"

    if kill -0 "$pid" 2>/dev/null; then
      alive=1
    else
      alive=0
    fi

    if [[ "$alive" -eq 1 && -d "/proc/$pid" ]]; then
      process_name="$(tr -d '\0' < "/proc/$pid/comm" 2>/dev/null || echo "unknown")"
      vmrss_kb="$(awk '/^VmRSS:/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)"
      memory_mb="$(awk "BEGIN {printf \"%.1f\", ${vmrss_kb:-0} / 1024.0}")"
      cpu_raw="$(ps -o cputime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0:00.00")"
      cpu_min="${cpu_raw%%:*}"
      cpu_sec="${cpu_raw#*:}"
      if [[ "$cpu_sec" == *.* ]]; then
        cpu_sec_int="${cpu_sec%%.*}"
        cpu_sec_frac="${cpu_sec#*.}"
      else
        cpu_sec_int="$cpu_sec"
        cpu_sec_frac="00"
      fi
      cpu_seconds="$(awk "BEGIN {printf \"%.1f\", ${cpu_min:-0} * 60 + ${cpu_sec_int:-0} + ${cpu_sec_frac:-0} / 100.0}")"
    else
      process_name="unknown"
      memory_mb="0.0"
      cpu_seconds="0.0"
    fi

    log_age_minutes="0.0"
    if [[ -n "$log_path" && -f "$log_path" ]]; then
      log_mtime="$(stat -c %Y "$log_path" 2>/dev/null || echo 0)"
      now_ts="$(date +%s)"
      log_age_minutes="$(awk "BEGIN {printf \"%.1f\", (${now_ts:-0} - ${log_mtime:-0}) / 60.0}")"
    fi

    if [[ "$alive" -eq 0 ]]; then
      health_status="dead"
      status_detail="null"
    elif [[ "$log_age_minutes" != "0.0" ]] && awk "BEGIN {exit !(${log_age_minutes} > 10)}" 2>/dev/null; then
      health_status="stall"
      status_detail="null"
    else
      health_status="alive"
      status_detail="null"
    fi

    jq -cn \
      --arg task_id "$task_id" \
      --argjson pid "$pid" \
      --arg process_name "$process_name" \
      --arg status "$health_status" \
      --argjson status_detail "$status_detail" \
      --argjson memory_mb "$memory_mb" \
      --argjson cpu_seconds "$cpu_seconds" \
      --arg log_path "$log_path" \
      --argjson log_age_minutes "$log_age_minutes" \
      --arg cwd "$cwd" \
      --arg sampled_at "$(wsl_now)" \
      '{task_id:$task_id,pid:$pid,process_name:$process_name,status:$status,status_detail:$status_detail,memory_mb:$memory_mb,cpu_seconds:$cpu_seconds,log_path:$log_path,log_age_minutes:$log_age_minutes,cwd:$cwd,sampled_at:$sampled_at}'
    ;;
  *) usage ;;
esac
