#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config path}"; root="$(jq -r '.wsl.project_root' "$config")"; distro="$(jq -r '.wsl.distro_name' "$config")"
errors='[]'; add_error(){ errors="$(jq --arg v "$1" '. + [$v]' <<<"$errors")"; }
for cmd in bash git jq setsid ps pgrep flock; do command -v "$cmd" >/dev/null 2>&1 || add_error "missing:$cmd"; done
if command -v opencode >/dev/null 2>&1; then
  opencode_command="$(command -v opencode)"
  opencode_path="$(readlink -f "$opencode_command" 2>/dev/null || true)"
  [[ -n "$opencode_path" ]] || add_error "opencode-path-unresolved:$opencode_command"
  [[ "$opencode_path" != /mnt/c/* && "$opencode_path" != /mnt/d/* ]] || add_error "windows-opencode-not-allowed:$opencode_path"
  if grep -Eq '(/mnt/c|/mnt/d|powershell\.exe|cmd\.exe)' "$opencode_path" 2>/dev/null; then
    add_error "windows-wrapper-not-allowed:$opencode_path"
  fi
else
  add_error missing:opencode
fi
[[ -d "$root" ]] || add_error "missing-project-root:$root"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || add_error not-git-repository
[[ "$root" != /mnt/c/* && "$root" != /mnt/d/* ]] || add_error linux-filesystem-required
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git -C "$root" status --porcelain)"
  [[ -z "$dirty" || "$(jq -r '.wsl.allow_dirty_project // false' "$config")" == true ]] || add_error dirty-project-requires-baseline
fi
if command -v opencode >/dev/null 2>&1 && [[ "${opencode_path:-}" != /mnt/c/* && "${opencode_path:-}" != /mnt/d/* ]]; then
  available="$(opencode models 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//' || true)"
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    grep -Fqx "$model" <<<"$available" || add_error "model-not-listed:$model"
  done < <(jq -r '.models | [.implementation,.fallback,.validation] | .[]' "$config")
fi
ok=true; [[ "$errors" == '[]' ]] || ok=false
jq -cn --arg distro "$distro" --arg root "$root" --argjson ok "$ok" --argjson errors "$errors" '{ok:$ok,distro:$distro,project_root:$root,errors:$errors,checked_at:(now|todateiso8601)}'
[[ "$ok" == true ]] || exit 2
