#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

config="${1:?config path}"
install_dir="${HOME}/.opencode/bin"
expected_path="$install_dir/opencode"
profile_file="${HOME}/.profile"
auto_install="$(jq -r '.wsl.auto_install_opencode // true' "$config")"
requested_version="$(jq -r '.wsl.opencode_version // ""' "$config")"

json_result() {
  local ok="$1"; shift
  jq -cn --arg path "${1:-}" --arg version "${2:-}" --arg action "${3:-}" \
    --argjson ok "$ok" '{ok:$ok,path:$path,version:$version,action:$action}'
}

is_windows_wrapper() {
  local command_path="$1"
  [[ -n "$command_path" && -f "$command_path" ]] || return 1
  local elf_magic
  elf_magic="$(head -c 4 "$command_path" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ "$elf_magic" == "7f454c46" ]] && return 1
  grep -Eiq '(/mnt/[cd]/|powershell\.exe|cmd\.exe|\.exe([[:space:]]|$))' "$command_path"
}

resolve_opencode() {
  local command_path
  command_path="$(command -v opencode 2>/dev/null || true)"
  [[ -n "$command_path" ]] || return 1
  readlink -f "$command_path" 2>/dev/null || printf '%s\n' "$command_path"
}

valid_linux_opencode() {
  local path version
  path="$(resolve_opencode || true)"
  [[ -n "$path" && -x "$path" ]] || return 1
  [[ "$path" != /mnt/c/* && "$path" != /mnt/d/* ]] || return 1
  is_windows_wrapper "$path" && return 1
  version="$($path --version 2>/dev/null | head -n 1 || true)"
  [[ "$version" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

write_profile_path() {
  mkdir -p "$(dirname "$profile_file")"
  touch "$profile_file"
  if ! grep -Fqx 'export PATH="$HOME/.opencode/bin:$PATH"' "$profile_file" 2>/dev/null; then
    printf '\n# OpenCode Linux CLI managed by wsl-codex-opencode-orchestrator\nexport PATH="$HOME/.opencode/bin:$PATH"\n' >> "$profile_file"
  fi
}

remove_known_wrapper() {
  local command_path="$1"
  local legacy_path="${HOME}/bin/opencode"
  [[ "$command_path" == "$legacy_path" && -f "$legacy_path" ]] || return 0
  if is_windows_wrapper "$legacy_path"; then
    rm -f -- "$legacy_path"
  fi
}

if [[ "$auto_install" != true ]]; then
  if valid_linux_opencode; then
    path="$(resolve_opencode)"; version="$($path --version | head -n 1)"
    json_result true "$path" "$version" "already-present"
    exit 0
  fi
  json_result false "" "" "auto-install-disabled" >&2
  exit 2
fi

current_path="$(resolve_opencode || true)"
if valid_linux_opencode; then
  path="$(resolve_opencode)"; version="$($path --version | head -n 1)"
  write_profile_path
  export PATH="$install_dir:$PATH"
  json_result true "$path" "$version" "already-present"
  exit 0
fi

remove_known_wrapper "$current_path"
mkdir -p "$install_dir"
if [[ -n "$requested_version" ]]; then
  curl -fsSL https://opencode.ai/install | bash -s -- --version "$requested_version"
else
  curl -fsSL https://opencode.ai/install | bash
fi
write_profile_path
export PATH="$install_dir:$PATH"

path="$expected_path"
[[ -x "$path" ]] || { json_result false "$path" "" "install-verification-path-failed" >&2; exit 3; }
version="$($path --version 2>/dev/null | head -n 1 || true)"
[[ "$version" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || { json_result false "$path" "$version" "install-verification-version-failed" >&2; exit 4; }
json_result true "$path" "$version" "installed"
