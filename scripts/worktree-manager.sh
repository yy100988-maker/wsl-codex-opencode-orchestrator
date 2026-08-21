#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
action="${1:-}"; root="${2:-}"; task_id="${3:-}"
[[ -n "$action" && -n "$root" ]] || wsl_die "usage: worktree-manager.sh create|remove|archive|restore|disk-recovery ROOT TASK_ID [branch|archive|config]"
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
  disk-recovery)
    config="${task_id:-}"
    [[ -n "$config" && -f "$config" ]] || wsl_die "disk-recovery requires config file as third argument"
    state="$root/.opencode"
    [[ -d "$state" ]] || wsl_die "state directory not found: $state"

    threshold_mb="$(jq -er '.disk_recovery.threshold_mb // 1024' "$config")"
    archive_max_age="$(jq -er '.disk_recovery.archive_max_age_days // 30' "$config")"
    failed_archive_max_age="$(jq -er '.disk_recovery.failed_archive_max_age_days // 7' "$config")"
    del_completed="$(jq -er '.disk_recovery.delete_completed_worktrees // true' "$config")"
    dry_run="$(jq -er '.disk_recovery.dry_run // false' "$config")"

    size_mb="$(du -sm "$state" 2>/dev/null | awk '{print $1}')"
    wsl_append_event "$state" disk_recovery_check _ "$(jq -cn --argjson size "$size_mb" --argjson threshold "$threshold_mb" --argjson dry "$dry_run" '{size_mb:$size,threshold_mb:$threshold,dry_run:$dry}')"

    if (( size_mb <= threshold_mb )); then
      wsl_append_event "$state" disk_recovery_completed _ '{"reason":"below_threshold"}'
      exit 0
    fi

    deleted=0

    # Phase 1: Delete expired task archives (exclude archives/events)
    while IFS= read -r -d '' dir; do
      name="$(basename "$dir")"
      [[ "$name" == "events" ]] && continue
      candidate="$(wsl_abs "$dir")"
      wsl_is_within "$candidate" "$state/archives" || { echo "WARNING: path outside archives: $candidate" >&2; continue; }
      if (( archive_max_age > 0 )); then
        if [[ -d "$dir" ]] && find "$dir" -maxdepth 0 -mtime +"$archive_max_age" -print -quit 2>/dev/null | grep -q .; then
          sz="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"
          wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "expired-archive" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
          if [[ "$dry_run" != true ]]; then rm -rf "$dir"; fi
          deleted=$((deleted+1))
        fi
      fi
    done < <(find "$state/archives" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

    # Phase 2: Delete completed worktrees that passed gate
    if [[ "$del_completed" == true ]]; then
      while IFS= read -r -d '' wt_dir; do
        task_id_c="$(basename "$wt_dir")"
        [[ -z "$task_id_c" ]] && continue
        if [[ -f "$state/tasks.json" ]] && [[ -f "$state/gates/${task_id_c}.json" ]]; then
          task_status="$(jq -er --arg id "$task_id_c" 'first(.tasks[] | select(.id == $id) | .status) // empty' "$state/tasks.json" 2>/dev/null || true)"
          if [[ "$task_status" == "done" || "$task_status" == "merged" ]]; then
            candidate="$(wsl_abs "$wt_dir")"
            wsl_is_within "$candidate" "$state/worktrees" || { echo "WARNING: path outside worktrees: $candidate" >&2; continue; }
            sz="$(du -sm "$wt_dir" 2>/dev/null | awk '{print $1}')"
            wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "completed-worktree" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
            if [[ "$dry_run" != true ]]; then
              git -C "$root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
              git -C "$root" worktree prune >/dev/null 2>&1 || true
            fi
            deleted=$((deleted+1))
          fi
        fi
      done < <(find "$state/worktrees" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    fi

    # Phase 3: Delete expired failed task archives
    while IFS= read -r -d '' dir; do
      candidate="$(wsl_abs "$dir")"
      wsl_is_within "$candidate" "$state/archives" || { echo "WARNING: path outside archives: $candidate" >&2; continue; }
      if [[ -f "$dir/manifest.json" ]]; then
        task_status="$(jq -er '.task_status // empty' "$dir/manifest.json" 2>/dev/null || true)"
        if [[ "$task_status" == "failed" || "$task_status" == "blocked" ]]; then
          if (( failed_archive_max_age > 0 )); then
            if [[ -d "$dir" ]] && find "$dir" -maxdepth 0 -mtime +"$failed_archive_max_age" -print -quit 2>/dev/null | grep -q .; then
              sz="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"
              wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "expired-failed-archive" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
              if [[ "$dry_run" != true ]]; then rm -rf "$dir"; fi
              deleted=$((deleted+1))
            fi
          fi
        fi
      fi
    done < <(find "$state/archives" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

    wsl_append_event "$state" disk_recovery_completed _ "$(jq -cn --argjson deleted "$deleted" --argjson dry "$dry_run" --argjson size "$size_mb" '{deleted:$deleted,dry_run:$dry,size_mb:$size}')"
    printf 'disk-recovery: deleted=%d dry_run=%s size_mb=%d\n' "$deleted" "$dry_run" "$size_mb"
    ;;
  *) wsl_die "unknown action: $action";;
esac

invoke_disk_recovery() {
  local root="$1"
  local config="$2"
  local dry_run="${3:-false}"

  local state="$root/.opencode"
  [[ -d "$state" ]] || wsl_die "state directory not found: $state"
  [[ -f "$config" ]] || wsl_die "config file not found: $config"

  local threshold_mb archive_max_age failed_archive_max_age del_completed
  threshold_mb="$(jq -er '.disk_recovery.threshold_mb // 1024' "$config")"
  archive_max_age="$(jq -er '.disk_recovery.archive_max_age_days // 30' "$config")"
  failed_archive_max_age="$(jq -er '.disk_recovery.failed_archive_max_age_days // 7' "$config")"
  del_completed="$(jq -er '.disk_recovery.delete_completed_worktrees // true' "$config")"

  local size_mb deleted=0
  size_mb="$(du -sm "$state" 2>/dev/null | awk '{print $1}')"
  wsl_append_event "$state" disk_recovery_check _ "$(jq -cn --argjson size "$size_mb" --argjson threshold "$threshold_mb" --argjson dry "$dry_run" '{size_mb:$size,threshold_mb:$threshold,dry_run:$dry}')"

  if (( size_mb <= threshold_mb )); then
    wsl_append_event "$state" disk_recovery_completed _ '{"reason":"below_threshold"}'
    return 0
  fi

  # Phase 1: Delete expired task archives (exclude archives/events)
  local dir name candidate sz
  while IFS= read -r -d '' dir; do
    name="$(basename "$dir")"
    [[ "$name" == "events" ]] && continue
    candidate="$(wsl_abs "$dir")"
    wsl_is_within "$candidate" "$state/archives" || { echo "WARNING: path outside archives: $candidate" >&2; continue; }
    if (( archive_max_age > 0 )); then
      if [[ -d "$dir" ]] && find "$dir" -maxdepth 0 -mtime +"$archive_max_age" -print -quit 2>/dev/null | grep -q .; then
        sz="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"
        wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "expired-archive" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
        if [[ "$dry_run" != true ]]; then rm -rf "$dir"; fi
        deleted=$((deleted+1))
      fi
    fi
  done < <(find "$state/archives" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  # Phase 2: Delete completed worktrees that passed gate
  local wt_dir task_id_c task_status
  if [[ "$del_completed" == true ]]; then
    while IFS= read -r -d '' wt_dir; do
      task_id_c="$(basename "$wt_dir")"
      [[ -z "$task_id_c" ]] && continue
      if [[ -f "$state/tasks.json" ]] && [[ -f "$state/gates/${task_id_c}.json" ]]; then
        task_status="$(jq -er --arg id "$task_id_c" 'first(.tasks[] | select(.id == $id) | .status) // empty' "$state/tasks.json" 2>/dev/null || true)"
        if [[ "$task_status" == "done" || "$task_status" == "merged" ]]; then
          candidate="$(wsl_abs "$wt_dir")"
          wsl_is_within "$candidate" "$state/worktrees" || { echo "WARNING: path outside worktrees: $candidate" >&2; continue; }
          sz="$(du -sm "$wt_dir" 2>/dev/null | awk '{print $1}')"
          wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "completed-worktree" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
          if [[ "$dry_run" != true ]]; then
            git -C "$root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
            git -C "$root" worktree prune >/dev/null 2>&1 || true
          fi
          deleted=$((deleted+1))
        fi
      fi
    done < <(find "$state/worktrees" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  fi

  # Phase 3: Delete expired failed task archives
  local task_status
  while IFS= read -r -d '' dir; do
    candidate="$(wsl_abs "$dir")"
    wsl_is_within "$candidate" "$state/archives" || { echo "WARNING: path outside archives: $candidate" >&2; continue; }
    if [[ -f "$dir/manifest.json" ]]; then
      task_status="$(jq -er '.task_status // empty' "$dir/manifest.json" 2>/dev/null || true)"
      if [[ "$task_status" == "failed" || "$task_status" == "blocked" ]]; then
        if (( failed_archive_max_age > 0 )); then
          if [[ -d "$dir" ]] && find "$dir" -maxdepth 0 -mtime +"$failed_archive_max_age" -print -quit 2>/dev/null | grep -q .; then
            sz="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"
            wsl_append_event "$state" disk_recovery_delete _ "$(jq -cn --arg path "$candidate" --arg reason "expired-failed-archive" --argjson size "$sz" --argjson dry "$dry_run" '{path:$path,reason:$reason,size_mb:$size,dry_run:$dry}')"
            if [[ "$dry_run" != true ]]; then rm -rf "$dir"; fi
            deleted=$((deleted+1))
          fi
        fi
      fi
    fi
  done < <(find "$state/archives" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  wsl_append_event "$state" disk_recovery_completed _ "$(jq -cn --argjson deleted "$deleted" --argjson dry "$dry_run" --argjson size "$size_mb" '{deleted:$deleted,dry_run:$dry,size_mb:$size}')"
  printf 'disk-recovery: deleted=%d dry_run=%s size_mb=%d\n' "$deleted" "$dry_run" "$size_mb"
}
