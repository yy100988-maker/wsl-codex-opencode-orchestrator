#!/usr/bin/env bash
set -euo pipefail

root="${1:?project root}"
config="${2:?config path}"
tasks="$root/.opencode/tasks.json"
errors='[]'
add_error(){ errors="$(jq --arg v "$1" '. + [$v]' <<<"$errors")"; }

uses_pnpm=false
if [[ -f "$tasks" ]] && jq -e '.tasks[] | select((.test_command // "") | test("(^|[[:space:]])pnpm([[:space:]]|$)"))' "$tasks" >/dev/null 2>&1; then uses_pnpm=true; fi
[[ -f "$root/pnpm-lock.yaml" ]] && uses_pnpm=true

if [[ "$uses_pnpm" == true ]]; then
  for command_name in node pnpm; do
    command -v "$command_name" >/dev/null 2>&1 || { add_error "missing:$command_name"; continue; }
    resolved="$(readlink -f "$(command -v "$command_name")" 2>/dev/null || command -v "$command_name")"
    [[ "$resolved" != /mnt/c/* && "$resolved" != /mnt/d/* && "$resolved" != *.exe ]] || add_error "windows-runtime-not-allowed:$command_name:$resolved"
  done
  if command -v node >/dev/null 2>&1; then node --version >/dev/null 2>&1 || add_error node-version-failed; fi
  if command -v pnpm >/dev/null 2>&1; then pnpm --version >/dev/null 2>&1 || add_error pnpm-version-failed; fi
  dangling="$(find "$root" -type l -path '*/node_modules/*' ! -exec test -e {} \; -print -quit 2>/dev/null || true)"
  missing_tree=false; [[ -f "$root/pnpm-lock.yaml" && ! -d "$root/node_modules" ]] && missing_tree=true
  if [[ ( -n "$dangling" || "$missing_tree" == true ) && "$(jq -r '.wsl.auto_install_project_dependencies // true' "$config")" == true ]]; then
    (cd "$root" && pnpm install --frozen-lockfile) >/dev/null 2>&1 || add_error pnpm-install-failed
    dangling="$(find "$root" -type l -path '*/node_modules/*' ! -exec test -e {} \; -print -quit 2>/dev/null || true)"
  fi
  [[ -z "$dangling" ]] || add_error "dangling-node-module-link:$dangling"
fi

ok=true; [[ "$errors" == '[]' ]] || ok=false
jq -cn --argjson ok "$ok" --argjson errors "$errors" '{ok:$ok,errors:$errors,checked_at:(now|todateiso8601)}'
[[ "$ok" == true ]]
