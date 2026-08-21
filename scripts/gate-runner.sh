#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
root="${1:?root}"; task_id="${2:?task-id}"; wt="${3:?worktree}"; task_json="$root/.opencode/tasks.json"; out="$root/.opencode/gates/$task_id/result.json"
mkdir -p "$(dirname "$out")"

allowed="$(jq -c --arg id "$task_id" 'first(.tasks[] | select(.id == $id) | .allowed_files) // []' "$task_json")"
handoff_file="$wt/.opencode-handoff.json"
handoff_ok=false; scope_ok=false; static_ok=false; tests_ok="not-configured"; changed='[]'; error=''; base_commit=''; branch_commit=''; required='["scope","handoff","static"]'

task_record="$(jq -c --arg id "$task_id" 'first(.tasks[] | select(.id == $id)) // {}' "$task_json")"
base_commit="$(jq -r '.base_commit // empty' <<<"$task_record")"
branch_commit="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$base_commit" ]]; then error="task-base-commit-missing"; fi
if [[ -n "$base_commit" && -n "$branch_commit" ]]; then
  git -C "$root" cat-file -e "$base_commit^{commit}" >/dev/null 2>&1 || error="task-base-commit-invalid"
  git -C "$wt" merge-base --is-ancestor "$base_commit" "$branch_commit" >/dev/null 2>&1 || error="task-base-commit-not-ancestor"
fi
required="$(jq -c '(.required_gates // ["scope","handoff","static"]) + (if (.test_command // "") != "" then ["unit"] else [] end) | unique' <<<"$task_record")"
for required_gate in contract integration security; do
  if jq -e --arg gate "$required_gate" 'index($gate) != null' <<<"$required" >/dev/null 2>&1; then
    configured="$(jq -r --arg gate "$required_gate" '.gate_commands[$gate] // empty' <<<"$task_record")"
    [[ -n "$configured" ]] || error="${error:-$required_gate-gate-not-configured}"
  fi
done

if [[ ! -f "$handoff_file" ]]; then
  error="handoff-missing"
else
  handoff_task="$(jq -r '.task_id // empty' "$handoff_file" 2>/dev/null || true)"
  handoff_status="$(jq -r '.status // empty' "$handoff_file" 2>/dev/null || true)"
  handoff_files="$(jq -c '.changed_files // []' "$handoff_file" 2>/dev/null || printf '[]')"
  [[ "$handoff_task" == "$task_id" ]] || error="handoff-task-id-mismatch"
  [[ "$handoff_status" == "completed" || "$handoff_status" == "passed" ]] || error="handoff-status-invalid"
  if [[ -z "$error" ]]; then handoff_ok=true; fi

  committed="$(git -C "$wt" -c core.quotepath=false diff --name-only "$base_commit" "$branch_commit" || true)"
  tracked="$(git -C "$wt" -c core.quotepath=false diff --name-only "$branch_commit" -- || true)"
  untracked="$(git -C "$wt" -c core.quotepath=false ls-files --others --exclude-standard || true)"
  changed="$(printf '%s\n%s\n%s\n' "$committed" "$tracked" "$untracked" | sed '/^$/d' | grep -vE '^(\.opencode-handoff\.json|\.opencode-task-prompt\.md)$' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
  handoff_files_sorted="$(jq -c 'sort' <<<"$handoff_files")"
  changed_sorted="$(jq -c 'sort' <<<"$changed")"
  [[ "$branch_commit" != "$base_commit" ]] || error="${error:-empty-task-branch}"
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
if jq -e 'index("unit") != null' <<<"$required" >/dev/null 2>&1 && [[ "$tests_ok" != true ]]; then passed=false; error="${error:-unit-gate-not-configured}"; fi
jq_unit="$tests_ok"; jq -cn --argjson scope "$scope_ok" --argjson handoff "$handoff_ok" --argjson static "$static_ok" --arg unit "$jq_unit" --argjson required "$required" '{scope:$scope,handoff:$handoff,static:$static,unit:$unit,required_gates:$required,contract:(if ($required|index("contract")) then "not-configured" else "not-required" end),integration:(if ($required|index("integration")) then "not-configured" else "not-required" end),security:(if ($required|index("security")) then "not-configured" else "not-required" end)}' > "$out.gates"
gates="$(cat "$out.gates")"; rm -f "$out.gates"
jq -cn --arg task_id "$task_id" --arg base_commit "$base_commit" --arg branch_commit "$branch_commit" --argjson passed "$passed" --argjson gates "$gates" --argjson changed "$changed" --arg error "$error" \
  '{task_id:$task_id,base_commit:$base_commit,branch_commit:$branch_commit,passed:$passed,gates:$gates,changed_files:$changed,error:(if $error == "" then null else $error end),checked_at:(now|todateiso8601)}' > "$out"
cat "$out"
[[ "$passed" == true ]]
