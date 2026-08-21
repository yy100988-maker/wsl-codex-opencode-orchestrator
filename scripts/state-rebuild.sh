#!/usr/bin/env bash
set -euo pipefail
root="${1:?project root}"; state="$root/.opencode/orchestrator-state.json"; events="$root/.opencode/events"; tmp="$state.tmp.$$"
[[ -d "$events" ]] || { printf '{"active":[],"history":[],"rebuilt":false,"reason":"events-directory-missing"}\n'; exit 2; }
finished="$(find "$events" -type f -name '*.jsonl' ! -path '*/archives/*' -print0 | xargs -0 -r cat | jq -s '[.[] | select(.event_type == "task-finished" or .event_type == "task-timeout" or .event_type == "task-blocked" or .event_type == "task-merged") | {task_id,status:(if .event_type == "task-merged" then "done" else (.data.status // (if .event_type == "task-finished" then "blocked" else "blocked" end)) end),reason:(.data.reason // .event_type),at:.timestamp}] | sort_by(.at) | group_by(.task_id) | map(last)')"
started="$(find "$events" -type f -name '*.jsonl' ! -path '*/archives/*' -print0 | xargs -0 -r cat | jq -s '[.[] | select(.event_type == "task-started") | {task_id,model:(.data.model // null),worktree:(.data.worktree // null),started_at:.timestamp}]')"
rebuilt="$(jq -cn --argjson history "$finished" --argjson started "$started" '{schema_version:1,active:[$started[] as $s | select(([ $history[] | select(.task_id == $s.task_id) ] | length) == 0) | {task_id:$s.task_id,status:"running",model:$s.model,worktree:$s.worktree,started_at:$s.started_at}],history:$history,rebuilt_at:(now|todateiso8601)}')"
printf '%s\n' "$rebuilt" > "$tmp"; mv "$tmp" "$state"; printf '%s\n' "$rebuilt"
