#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
root="${1:?root}"; task_id="${2:?task-id}"; wt="${3:?worktree}"; task_json="$root/.opencode/tasks.json"; out="$root/.opencode/gates/$task_id/result.json"
mkdir -p "$(dirname "$out")"

allowed="$(jq -c --arg id "$task_id" 'first(.tasks[] | select(.id == $id) | .allowed_files) // []' "$task_json")"
handoff_file="$wt/.opencode-handoff.json"
handoff_ok=false; scope_ok=false; static_ok=false; tests_ok="not-configured"; changed='[]'; error=''

if [[ ! -f "$handoff_file" ]]; then
  error="handoff-missing"
else
  handoff_task="$(jq -r '.task_id // empty' "$handoff_file" 2>/dev/null || true)"
  handoff_status="$(jq -r '.status // empty' "$handoff_file" 2>/dev/null || true)"
  handoff_files="$(jq -c '.changed_files // []' "$handoff_file" 2>/dev/null || printf '[]')"
  [[ "$handoff_task" == "$task_id" ]] || error="handoff-task-id-mismatch"
  [[ "$handoff_status" == "completed" || "$handoff_status" == "passed" ]] || error="handoff-status-invalid"
  if [[ -z "$error" ]]; then handoff_ok=true; fi

  base_commit="$(git -C "$root" rev-parse HEAD)"
  branch_commit="$(git -C "$wt" rev-parse HEAD)"
  committed="$(git -C "$wt" diff --name-only "$base_commit" "$branch_commit" || true)"
  tracked="$(git -C "$wt" diff --name-only "$branch_commit" -- || true)"
  untracked="$(git -C "$wt" ls-files --others --exclude-standard || true)"
  changed="$(printf '%s\n%s\n%s\n' "$committed" "$tracked" "$untracked" | sed '/^$/d' | grep -vE '^(\.opencode-handoff\.json|\.opencode-task-prompt\.md)$' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
  handoff_files_sorted="$(jq -c 'sort' <<<"$handoff_files")"
  changed_sorted="$(jq -c 'sort' <<<"$changed")"
  if [[ "$changed_sorted" == "$handoff_files_sorted" ]]; then
    scope_ok=true
  else
    error="handoff-changed-files-mismatch"
  fi
  while IFS= read -r file; do
    allowed_file=false
    while IFS= read -r pattern; do
      wsl_task_allowed "$file" "$pattern" && allowed_file=true
    done < <(jq -r '.[]' <<<"$allowed")
    [[ "$allowed_file" == true ]] || scope_ok=false
  done < <(jq -r '.[]' <<<"$changed")
fi

if git -C "$wt" diff --check >/dev/null 2>&1; then static_ok=true; else error="${error:-static-check-failed}"; fi
test_command="$(jq -r --arg id "$task_id" 'first(.tasks[] | select(.id == $id) | .test_command) // empty' "$task_json")"
if [[ -n "$test_command" ]]; then
  if (cd "$wt" && bash -lc "$test_command") >"$root/.opencode/gates/$task_id/test.log" 2>&1; then tests_ok=true; else tests_ok=false; error="${error:-test-command-failed}"; fi
fi

passed=false
if [[ "$handoff_ok" == true && "$scope_ok" == true && "$static_ok" == true && "$tests_ok" != false ]]; then passed=true; fi
jq_unit="$tests_ok"; jq -cn --argjson scope "$scope_ok" --argjson handoff "$handoff_ok" --argjson static "$static_ok" --arg unit "$jq_unit" '{scope:$scope,handoff:$handoff,static:$static,unit:$unit,contract:"not-configured",integration:"not-configured",security:"not-configured"}' > "$out.gates"
gates="$(cat "$out.gates")"; rm -f "$out.gates"
jq -cn --arg task_id "$task_id" --argjson passed "$passed" --argjson gates "$gates" --argjson changed "$changed" --arg error "$error" \
  '{task_id:$task_id,passed:$passed,gates:$gates,changed_files:$changed,error:(if $error == "" then null else $error end),checked_at:(now|todateiso8601)}' > "$out"
cat "$out"
[[ "$passed" == true ]]
