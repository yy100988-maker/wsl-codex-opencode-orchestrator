#!/usr/bin/env bash
set -euo pipefail

config="${1:?config path}"
root="$(jq -r '.wsl.project_root' "$config")"
target="$(jq -r '.wsl.source_project_root // empty' "$config")"
[[ -n "$target" && -d "$target" ]] || { printf '{"ok":false,"error":"source_project_root-missing"}\n' >&2; exit 2; }
source_state="$root/.opencode"
target_state="$target/.opencode"
[[ -d "$source_state" ]] || { printf '{"ok":false,"error":"source-opencode-missing"}\n' >&2; exit 3; }
mkdir -p "$target_state"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$target_state/sync-backups/$stamp"
mkdir -p "$backup"

for item in tasks.json orchestrator-state.json task-graph.jsonl leases.json task-decomposition.json; do
  [[ -f "$target_state/$item" ]] && cp -f "$target_state/$item" "$backup/$item"
  [[ -f "$source_state/$item" ]] && cp -f "$source_state/$item" "$target_state/$item"
done
for dir in reports gates archives metrics controller-memory knowledge-base prompts; do
  [[ -d "$source_state/$dir" ]] || continue
  mkdir -p "$target_state/$dir"
  cp -a "$source_state/$dir/." "$target_state/$dir/"
done

source_commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
target_commit="$(git -C "$target" rev-parse HEAD 2>/dev/null || true)"
jq -cn --arg source_root "$root" --arg target_root "$target" --arg source_commit "$source_commit" --arg target_commit "$target_commit" --arg backup "$backup" '{ok:true,source_root:$source_root,target_root:$target_root,source_commit:$source_commit,target_commit:$target_commit,backup:$backup,synced_at:(now|todateiso8601)}' | tee "$target_state/sync-manifest.json"
