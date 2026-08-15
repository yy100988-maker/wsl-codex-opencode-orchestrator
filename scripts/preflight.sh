#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/common.sh"
config="${1:?config path}"; root="$(jq -r '.wsl.project_root' "$config")"; distro="$(jq -r '.wsl.distro_name' "$config")"
errors='[]'; add_error(){ errors="$(jq --arg v "$1" '. + [$v]' <<<"$errors")"; }
for cmd in bash git jq setsid ps pgrep; do command -v "$cmd" >/dev/null 2>&1 || add_error "missing:$cmd"; done
command -v opencode >/dev/null 2>&1 || add_error missing:opencode
[[ -d "$root" ]] || add_error "missing-project-root:$root"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || add_error not-git-repository
[[ "$root" != /mnt/c/* && "$root" != /mnt/d/* ]] || add_error linux-filesystem-required
available="$(opencode models 2>/dev/null || true)"
while IFS= read -r model; do grep -Fqx "$model" <<<"$available" || add_error "model-not-listed:$model"; done < <(jq -r '.models | [.implementation,.fallback,.validation] | .[]' "$config")
ok=true; [[ "$errors" == '[]' ]] || ok=false
jq -cn --arg distro "$distro" --arg root "$root" --argjson ok "$ok" --argjson errors "$errors" '{ok:$ok,distro:$distro,project_root:$root,errors:$errors,checked_at:(now|todateiso8601)}'
[[ "$ok" == true ]] || exit 2
