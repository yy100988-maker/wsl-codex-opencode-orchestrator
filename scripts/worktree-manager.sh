#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
action="${1:-}"; root="${2:-}"; task_id="${3:-}"
[[ -n "$action" && -n "$root" && -n "$task_id" ]] || wsl_die "usage: worktree-manager.sh create|remove|archive ROOT TASK_ID [branch]"
state="$root/.opencode"; wt="$state/worktrees/$task_id"; branch="${4:-codex/task-$task_id}"
case "$action" in
 create)
   mkdir -p "$state/worktrees"
   [[ ! -e "$wt" ]] || wsl_die "worktree already exists: $wt"
   git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || git -C "$root" branch "$branch"
   git -C "$root" worktree add "$wt" "$branch" >/dev/null
   jq -cn --arg path "$wt" --arg branch "$branch" '{path:$path,branch:$branch,created_at:(now|todateiso8601)}'
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
     base_commit="$(git -C "$root" rev-parse HEAD)"
     branch_commit="$(git -C "$wt" rev-parse HEAD)"
     git -C "$wt" diff --binary "$base_commit" "$branch_commit" > "$archive/changes.patch" 2>/dev/null || true
     git -C "$wt" diff --binary "$branch_commit" >> "$archive/changes.patch" 2>/dev/null || true
     git -C "$wt" ls-files --others --exclude-standard -z | while IFS= read -r -d '' file; do
       mkdir -p "$archive/untracked/$(dirname "$file")"
       cp -f "$wt/$file" "$archive/untracked/$file"
     done
   else
     : > "$archive/changes.patch"
   fi
   git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
   git -C "$root" worktree prune >/dev/null 2>&1 || true
   ;;
 *) wsl_die "unknown action: $action";;
esac
