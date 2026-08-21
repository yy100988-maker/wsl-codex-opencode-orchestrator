#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
action="${1:-}"; state="${2:-}"; task_id="${3:-}"; files="${4:-[]}"; ttl="${5:-3600}"
leases="$(dirname "$state")/leases.json"; mkdir -p "$(dirname "$leases")"; [[ -f "$leases" ]] || printf '[]\n' > "$leases"
exec 9>"$leases.lock"; flock -x 9
jq -e 'type == "array" and all(.[]; (.task_id | type == "string") and (.files | type == "array") and (.expires_at | type == "number"))' "$leases" >/dev/null || wsl_die "invalid leases schema: $leases"
case "$action" in
 acquire)
  jq -ne --argjson files "$files" '$files | type == "array"' >/dev/null || wsl_die "invalid lease files JSON"
  now="$(date +%s)"; expiry=$((now + ttl))
  if jq -e --arg task_id "$task_id" --argjson files "$files" --argjson now "$now" 'any(.[]; .expires_at > $now and (.task_id != $task_id) and any(.files[] as $a | $files[] as $b | ($a==$b or ($a|startswith($b+"/")) or ($b|startswith($a+"/")))))' "$leases" >/dev/null; then exit 3; fi
  if jq -e --arg task_id "$task_id" --argjson now "$now" 'any(.[]; .expires_at > $now and .task_id == $task_id)' "$leases" >/dev/null; then exit 0; fi
  tmp="$leases.tmp.$$"; jq --arg task_id "$task_id" --argjson files "$files" --argjson expires "$expiry" '. + [{task_id:$task_id,files:$files,expires_at:$expires,acquired_at:(now|todateiso8601)}]' "$leases" > "$tmp"; mv "$tmp" "$leases";;
 release)
  tmp="$leases.tmp.$$"; jq --arg task_id "$task_id" 'map(select(.task_id != $task_id))' "$leases" > "$tmp"; mv "$tmp" "$leases";;
 purge)
  now="$(date +%s)"; tmp="$leases.tmp.$$"; jq --argjson now "$now" 'map(select(.expires_at > $now))' "$leases" > "$tmp"; mv "$tmp" "$leases";;
 *) wsl_die "usage: lease-manager.sh acquire|release|purge STATE TASK_ID FILES_JSON [TTL]";;
esac
