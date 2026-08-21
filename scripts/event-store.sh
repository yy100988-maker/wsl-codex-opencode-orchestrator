#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

wsl_compress_events() {
  local events_dir="$1"
  local archive_dir="$2"
  local full_keep_days="$3"
  local summary_start_days="$4"
  local archive_after_days="$5"

  [[ -d "$events_dir" ]] || return 0

  local today_epoch
  today_epoch=$(date -u +%s)
  local lock_file="$events_dir/.compress.lock"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  {
    flock -x 9

    mkdir -p "$archive_dir"

    local compressed_count=0
    local archived_count=0

    while IFS= read -r -d '' file; do
      local basename
      basename=$(basename "$file")
      [[ "$basename" == *.jsonl ]] || continue
      [[ "$basename" == *.summary.jsonl ]] && continue

      local date_str="${basename%.jsonl}"
      local file_epoch
      file_epoch=$(date -u -d "$date_str" +%s 2>/dev/null) || continue

      local age_days=$(( (today_epoch - file_epoch) / 86400 ))

      if (( age_days >= archive_after_days )); then
        local dest="$archive_dir/$basename"
        if [[ -f "$dest" ]]; then
          dest="$archive_dir/${date_str}-$(date -u +%s).jsonl"
        fi
        mv "$file" "$dest"
        [[ -f "$file.lock" ]] && mv "$file.lock" "$dest.lock"
        archived_count=$((archived_count + 1))

      elif (( age_days >= full_keep_days )); then
        local summary_file="$events_dir/${date_str}.summary.jsonl"
        local tmp_summary="$tmp_dir/${date_str}.summary.jsonl"
        local tmp_orig="$tmp_dir/${date_str}.orig.jsonl"

        jq -c '[.[] | {
          event_type,
          timestamp,
          task_id,
          data: {
            status: (.data.status // null),
            reason: (.data.reason // null)
          }
        }] | .[]' "$file" > "$tmp_summary"

        mv "$file" "$tmp_orig"
        mv "$tmp_summary" "$summary_file"
        [[ -f "$file.lock" ]] && rm -f "$file.lock"
        compressed_count=$((compressed_count + 1))
      fi
    done < <(find "$events_dir" -maxdepth 1 -type f -name '*.jsonl' -print0 2>/dev/null)

    if (( compressed_count > 0 || archived_count > 0 )); then
      local data
      data=$(jq -cn --argjson compressed "$compressed_count" --argjson archived "$archived_count" \
        '{compressed:$compressed,archived:$archived}')
      local state
      state=$(dirname "$events_dir")/orchestrator-state.json
      if [[ -f "$state" ]]; then
        wsl_append_event "$state" events_compressed "" "$data"
      fi
    fi
  } 9>"$lock_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  project_root="${1:?project root}"
  config="${2:-$project_root/.opencode/wsl-config.json}"

  events_dir="$project_root/.opencode/events"
  archive_dir=$(jq -r '.event_compress.archive_dir // ".opencode/archives/events"' "$config" 2>/dev/null || echo ".opencode/archives/events")
  full_keep_days=$(jq -r '.event_compress.full_keep_days // 7' "$config" 2>/dev/null || echo 7)
  summary_start_days=$(jq -r '.event_compress.summary_start_days // 7' "$config" 2>/dev/null || echo 7)
  archive_after_days=$(jq -r '.event_compress.archive_after_days // 30' "$config" 2>/dev/null || echo 30)

  [[ "$archive_dir" == /* ]] || archive_dir="$project_root/$archive_dir"

  wsl_compress_events "$events_dir" "$archive_dir" "$full_keep_days" "$summary_start_days" "$archive_after_days"
fi
