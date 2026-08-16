#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

root="${1:?project root}"
tasks_file="${2:-$root/.opencode/tasks.json}"
prompt_dir="${3:-$root/.opencode/prompts}"
[[ -f "$tasks_file" ]] || wsl_die "tasks manifest not found: $tasks_file"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || wsl_die "not a git repository: $root"

base_commit="$(git -C "$root" rev-parse HEAD)"
mkdir -p "$prompt_dir"
all_files="$(git -C "$root" ls-files -co --exclude-standard | sed '/^\.opencode\//d')"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
map_file="$tmp_dir/map.tsv"
children_file="$tmp_dir/children.jsonl"
: > "$map_file"
: > "$children_file"

slugify() { printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-80; }
matches_for_task() {
  local task_json="$1" file pattern matched=''
  while IFS= read -r file; do
    while IFS= read -r pattern; do
      if wsl_task_allowed "$file" "$pattern"; then matched+="$file\n"; break; fi
    done < <(jq -r '.allowed_files // [] | .[]' <<<"$task_json")
  done <<<"$all_files"
  printf '%b' "$matched" | sed '/^$/d' | sort -u
}

while IFS= read -r task; do
  orig="$(jq -r '.id' <<<"$task")"
  mapfile -t files < <(matches_for_task "$task")
  if ((${#files[@]} <= 1)); then
    printf '%s\t%s\n' "$orig" "$orig" >> "$map_file"
  else
    for file in "${files[@]}"; do printf '%s\t%s\n' "$orig" "${orig}--$(slugify "$file")" >> "$map_file"; done
  fi
done < <(jq -c '.tasks[]' "$tasks_file")

declare -A owner_by_file
while IFS= read -r task; do
  orig="$(jq -r '.id' <<<"$task")"
  mapfile -t files < <(matches_for_task "$task")
  ((${#files[@]} > 0)) || files=("")
  while IFS=$'\t' read -r map_orig child; do
    [[ "$map_orig" == "$orig" ]] || continue
    file="${files[0]}"
    files=("${files[@]:1}")
    prompt_path="$root/.opencode/prompts/$child.md"
    if [[ -n "$file" ]]; then
      allowed="$(jq -cn --arg f "$file" '[$f]')"
      claimed="$allowed"
      prompt_text="$(jq -r '.prompt // .design_slice // "Implement this task according to the task record."' <<<"$task")\n\n文件边界：只允许修改：$file"
      previous="${owner_by_file[$file]:-}"
      owner_by_file[$file]="$child"
    else
      allowed="$(jq -c '.allowed_files // []' <<<"$task")"
      claimed='[]'
      prompt_text="$(jq -r '.prompt // .design_slice // "Implement this task according to the task record."' <<<"$task")"
      previous=''
    fi
    deps="$(jq -c '.depends_on // []' <<<"$task")"
    mapped='[]'
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      dep_children="$(awk -F '\t' -v id="$dep" '$1 == id {print $2}' "$map_file" | jq -Rsc 'split("\n") | map(select(length > 0))')"
      mapped="$(jq -cn --argjson a "$mapped" --argjson b "$dep_children" '$a + $b | unique')"
    done < <(jq -r '.[]' <<<"$deps")
    [[ -z "$previous" ]] || mapped="$(jq -cn --argjson a "$mapped" --arg b "$previous" '$a + [$b] | unique')"
    out_task="$(jq -c --arg id "$child" --arg parent "$orig" --arg base "$base_commit" --arg prompt_file ".opencode/prompts/$child.md" --argjson allowed "$allowed" --argjson claimed "$claimed" --argjson deps "$mapped" '.id=$id | .base_commit=$base | .allowed_files=$allowed | .claimed_files=$claimed | .depends_on=$deps | .prompt_file=$prompt_file | .parallel_unit="source-file" | .decomposition_parent=$parent | .status="pending" | del(.status_reason,.attempt)' <<<"$task")"
    printf '%s\n' "$out_task" >> "$children_file"
    printf '%b\n' "$prompt_text" > "$prompt_path"
  done < "$map_file"
done < <(jq -c '.tasks[]' "$tasks_file")

tmp_tasks="$tasks_file.tmp.$$"
jq -s --argjson base "$(jq -n --arg v "$base_commit" '$v')" '{version:1,generated_at:(now|todateiso8601),base_commit:$base,tasks:.}' "$children_file" > "$tmp_tasks"
mv "$tmp_tasks" "$tasks_file"
jq -cn --arg base "$base_commit" --argjson count "$(wc -l < "$children_file")" '{base_commit:$base,task_count:$count,unit:"source-file",generated_at:(now|todateiso8601)}' > "$root/.opencode/task-decomposition.json"
printf '%s\n' "$root/.opencode/task-decomposition.json"
