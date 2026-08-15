#!/usr/bin/env bash
set -euo pipefail

wsl_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

wsl_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

wsl_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || wsl_die "missing command: $1"
}

wsl_abs() {
  realpath -m "$1"
}

wsl_config_get() {
  local config="$1"
  local filter="$2"
  jq -er "$filter" "$config"
}

wsl_ensure_state_dirs() {
  local state="$1"
  local root
  root="$(dirname "$state")"
  mkdir -p "$root/events" "$root/gates" "$root/logs" "$root/reports" "$root/archives" "$root/worktrees" "$root/controller-memory" "$root/processes" "$root/metrics"
  if [[ ! -f "$state" ]]; then
    printf '{"schema_version":1,"active":[],"history":[],"events":[],"memory":null}\n' > "$state"
  fi
  if [[ ! -f "$root/leases.json" ]]; then
    printf '[]\n' > "$root/leases.json"
  fi
}

wsl_atomic_jq() {
  local state="$1"
  shift
  local tmp
  tmp="$state.tmp.$$"
  jq "$@" "$state" > "$tmp"
  mv "$tmp" "$state"
}

wsl_append_event() {
  local state="$1"
  local event_type="$2"
  local task_id="$3"
  local data="$4"
  local event_file
  local line
  event_file="$(dirname "$state")/events/$(date -u +%Y-%m-%d).jsonl"
  line="$(jq -cn --arg event_id "evt-$(date -u +%s%N)" --arg event_type "$event_type" --arg task_id "$task_id" --arg timestamp "$(wsl_now)" --argjson data "$data" '{schema_version:1,event_id:$event_id,event_type:$event_type,task_id:$task_id,data:$data,timestamp:$timestamp}')"
  {
    flock -x 9
    printf '%s\n' "$line" >> "$event_file"
  } 9>"$event_file.lock"
}

wsl_lock_file() {
  local path="$1"
  exec 8>"$path.lock"
  flock -n 8
}

wsl_update_task_status() {
  local tasks="$1"
  local task_id="$2"
  local status="$3"
  local reason="${4:-}"
  local tmp="$tasks.tmp.$$"
  jq --arg id "$task_id" --arg status "$status" --arg reason "$reason" \
    '(.tasks[] | select(.id == $id) | .status) = $status |
     (.tasks[] | select(.id == $id) | .status_reason) = (if $reason == "" then .status_reason else $reason end)' \
    "$tasks" > "$tmp"
  mv "$tmp" "$tasks"
}

wsl_remove_active_task() {
  local state="$1"
  local task_id="$2"
  local tmp="$state.tmp.$$"
  jq --arg id "$task_id" '.active = ([.active[] | select(.task_id != $id)])' "$state" > "$tmp"
  mv "$tmp" "$state"
}

wsl_reconcile_task_manifest() {
  local tasks="$1"
  local state="$2"
  local tmp="$tasks.tmp.$$"
  jq --argjson history "$(jq -c '.history // []' "$state")" '
    reduce $history[] as $entry (.;
      (.tasks[] | select(.id == $entry.task_id) | .status) = $entry.status |
      (.tasks[] | select(.id == $entry.task_id) | .status_reason) = ($entry.reason // .status_reason)
    )' "$tasks" > "$tmp"
  mv "$tmp" "$tasks"
}

wsl_latest_status() {
  local state="$1"
  local task_id="$2"
  jq -r --arg task_id "$task_id" '([.history[] | select(.task_id == $task_id)] | sort_by(.at) | last.status) // "pending"' "$state"
}

wsl_task_allowed() {
  local file="$1"
  local pattern="$2"
  if [[ "$pattern" == *"**" ]]; then
    local prefix
    prefix="$(printf '%s' "$pattern" | sed 's/\*\*.*$//')"
    [[ "$file" == "$prefix"* ]]
  elif [[ "$pattern" == *"*" ]]; then
    local prefix
    prefix="$(printf '%s' "$pattern" | sed 's/\*.*$//')"
    [[ "$file" == "$prefix"* ]]
  else
    [[ "$file" == "$pattern" ]]
  fi
}

wsl_is_within() {
  local path="$1"
  local root="$2"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}
