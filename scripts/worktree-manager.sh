#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
action="${1:-}"; root="${2:-}"; task_id="${3:-}"
[[ -n "$action" && -n "$root" && -n "$task_id" ]] || wsl_die "usage: worktree-manager.sh create|remove|archive|restore ROOT TASK_ID [branch|archive]"
state="$root/.opencode"; wt="$state/worktrees/$task_id"; branch="${4:-codex/task-$task_id}"
case "$action" in
 create)
   mkdir -p "$state/worktrees"
   [[ ! -e "$wt" ]] || wsl_die "worktree already exists: $wt"
   base_commit="$(jq -r --arg id "$task_id" 'first(.tasks[] | select(.id == $id) | .base_commit) // empty' "$state/tasks.json" 2>/dev/null || true)"
   [[ -n "$base_commit" ]] || base_commit="$(git -C "$root" rev-parse HEAD)"
   git -C "$root" cat-file -e "$base_commit^{commit}" || wsl_die "invalid base commit: $base_commit"
   git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || git -C "$root" branch "$branch" "$base_commit"
   git -C "$root" worktree add "$wt" "$branch" >/dev/null
   jq -cn --arg path "$wt" --arg branch "$branch" --arg base "$base_commit" '{path:$path,branch:$branch,base_commit:$base,created_at:(now|todateiso8601)}'
   ;;
 remove)
   wsl_is_within "$wt" "$state/worktrees" || wsl_die "worktree outside managed directory"
   git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
   git -C "$root" worktree prune >/dev/null 2>&1 || true
   ;;
 archive)
   archive="$state/archives/$task_id-$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -p "$archive"
   wsl_is_within "$wt" "$state/worktrees" || wsl_die "worktree outside managed directory"
   if [[ -d "$wt" ]]; then
     base_commit="$(jq -r --arg id "$task_id" 'first(.tasks[] | select(.id == $id) | .base_commit) // empty' "$state/tasks.json" 2>/dev/null || true)"
     [[ -n "$base_commit" ]] || wsl_die "task base commit missing: $task_id"
     branch_commit="$(git -C "$wt" rev-parse HEAD)"
     git -C "$wt" diff --binary "$base_commit" "$branch_commit" > "$archive/changes.patch" 2>/dev/null || true
     git -C "$wt" diff --binary "$branch_commit" >> "$archive/changes.patch" 2>/dev/null || true
     committed="$(git -C "$wt" diff --name-only "$base_commit" "$branch_commit" || true)"
     tracked="$(git -C "$wt" diff --name-only "$branch_commit" -- || true)"
     untracked="$(git -C "$wt" ls-files --others --exclude-standard || true)"
     changed="$(printf '%s\n%s\n%s\n' "$committed" "$tracked" "$untracked" | sed '/^$/d' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
     jq -cn --arg task_id "$task_id" --arg base "$base_commit" --arg branch "$branch" --arg branch_commit "$branch_commit" --argjson changed "$changed" '{task_id:$task_id,base_commit:$base,branch:$branch,branch_commit:$branch_commit,changed_files:$changed,created_at:(now|todateiso8601)}' > "$archive/manifest.json"
     git -C "$wt" ls-files --others --exclude-standard -z | while IFS= read -r -d '' file; do
       mkdir -p "$archive/untracked/$(dirname "$file")"
       cp -f "$wt/$file" "$archive/untracked/$file"
     done
     if [[ -d "$archive/untracked" ]]; then (cd "$archive/untracked" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) > "$archive/hashes.sha256"; else : > "$archive/hashes.sha256"; fi
     [[ -f "$wt/.opencode-handoff.json" ]] && cp -f "$wt/.opencode-handoff.json" "$archive/.opencode-handoff.json"
   else
     : > "$archive/changes.patch"
     jq -cn --arg task_id "$task_id" '{task_id:$task_id,changed_files:[],created_at:(now|todateiso8601)}' > "$archive/manifest.json"
     : > "$archive/hashes.sha256"
   fi
   git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
   git -C "$root" worktree prune >/dev/null 2>&1 || true
   ;;
 restore)
   archive="${4:-}"
   [[ -d "$archive" ]] || wsl_die "archive not found: $archive"
   manifest="$archive/manifest.json"
   [[ -f "$manifest" ]] || wsl_die "archive manifest missing: $manifest"
   base_commit="$(jq -r '.base_commit // empty' "$manifest")"
   branch="${5:-codex/restore-$task_id}"
   [[ -n "$base_commit" ]] || wsl_die "archive base commit missing"
   git -C "$root" cat-file -e "$base_commit^{commit}" || wsl_die "invalid archive base commit: $base_commit"
   mkdir -p "$state/worktrees"
   [[ ! -e "$wt" ]] || wsl_die "worktree already exists: $wt"
   git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || git -C "$root" branch "$branch" "$base_commit"
   git -C "$root" worktree add "$wt" "$branch" >/dev/null
   [[ ! -s "$archive/changes.patch" ]] || git -C "$wt" apply --index "$archive/changes.patch"
   if [[ -d "$archive/untracked" ]]; then cp -a "$archive/untracked/." "$wt/"; fi
   if [[ -s "$archive/hashes.sha256" ]]; then (cd "$wt" && sha256sum -c "$archive/hashes.sha256") >/dev/null; fi
   printf '%s\n' "$wt"
   ;;
 *) wsl_die "unknown action: $action";;
esac
