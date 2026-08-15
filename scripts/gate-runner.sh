#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
root="${1:?root}"; task_id="${2:?task-id}"; task_json="$root/.opencode/tasks.json"; wt="$3"; out="$root/.opencode/gates/$task_id/result.json"
mkdir -p "$(dirname "$out")"
allowed="$(jq -c --arg id "$task_id" 'first(.tasks[]|select(.id==$id)|.allowed_files) // []' "$task_json")"
handoff_file="$wt/.opencode-handoff.json"; handoff_ok=false; scope=true; changed='[]'
if [[ ! -f "$handoff_file" ]]; then handoff_ok=false; else
 handoff_ok=true
 base_commit="$(git -C "$root" rev-parse HEAD)"
 changed_names="$(git -C "$wt" diff --name-only "$base_commit" --)"
 changed="$(printf '%s\n' "$changed_names" | jq -Rsc 'split("\n") | map(select(length > 0))')"
 while IFS= read -r file; do
   ok=false; for pattern in $(jq -r '.[]' <<<"$allowed"); do wsl_task_allowed "$file" "$pattern" && ok=true; done
   $ok || scope=false
 done < <(jq -r '.[]' <<<"$changed")
fi
static=true; tests=true
if [[ "$scope" == true && "$handoff_ok" == true ]]; then
  cmd="$(jq -r --arg id "$task_id" 'first(.tasks[]|select(.id==$id)|.test_command) // empty' "$task_json")"
  [[ -z "$cmd" ]] || (cd "$wt" && bash -lc "$cmd") || tests=false
else tests=false; fi
passed=false; [[ "$scope" == true && "$handoff_ok" == true && "$static" == true && "$tests" == true ]] && passed=true
jq -cn --arg task_id "$task_id" --argjson passed "$passed" --argjson scope "$scope" --argjson handoff "$handoff_ok" --argjson tests "$tests" --argjson changed "$changed" \
 '{task_id:$task_id,passed:$passed,gates:{scope:$scope,handoff:$handoff,static:true,unit:$tests,contract:true,integration:true,security:true},changed_files:$changed,checked_at:(now|todateiso8601)}' > "$out"
cat "$out"
