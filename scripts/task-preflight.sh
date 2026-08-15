#!/usr/bin/env bash
set -euo pipefail
root="${1:?project root}"; tasks="$root/.opencode/tasks.json"; errors='[]'
add_error(){ errors="$(jq --arg v "$1" '. + [$v]' <<<"$errors")"; }
while IFS= read -r task; do
  id="$(jq -r '.id' <<<"$task")"; command_line="$(jq -r '.test_command // empty' <<<"$task")"
  [[ -z "$command_line" ]] && continue
  command_name="$(basename "$(awk '{print $1}' <<<"$command_line")")"
  command -v "$command_name" >/dev/null 2>&1 || add_error "$id:missing-test-command:$command_name"
  if [[ "$command_line" == *"--filter "* ]]; then
    package_name="$(sed -n 's/.*--filter[[:space:]]\+\([^[:space:]]*\).*/\1/p' <<<"$command_line")"
    if [[ -n "$package_name" ]]; then
      found=false
      while IFS= read -r -d '' package_file; do
        if jq -e --arg name "$package_name" '.name == $name' "$package_file" >/dev/null 2>&1; then found=true; break; fi
      done < <(find "$root" -name package.json -not -path '*/node_modules/*' -print0)
      [[ "$found" == true ]] || add_error "$id:package-filter-not-found:$package_name"
    fi
  fi
done < <(jq -c '.tasks[]' "$tasks")
ok=true; [[ "$errors" == '[]' ]] || ok=false
jq -cn --argjson ok "$ok" --argjson errors "$errors" '{ok:$ok,errors:$errors,checked_at:(now|todateiso8601)}'
[[ "$ok" == true ]]
