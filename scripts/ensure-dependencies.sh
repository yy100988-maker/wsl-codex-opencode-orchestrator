#!/usr/bin/env bash
set -euo pipefail

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v git >/dev/null 2>&1 || missing+=(git)
command -v jq >/dev/null 2>&1 || missing+=(jq)
command -v setsid >/dev/null 2>&1 || missing+=(util-linux)
command -v ps >/dev/null 2>&1 || missing+=(procps)
command -v pgrep >/dev/null 2>&1 || missing+=(procps)
command -v flock >/dev/null 2>&1 || missing+=(util-linux)

if ((${#missing[@]} == 0)); then
  echo '{"ok":true,"installed":[],"message":"dependencies-present"}'
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  printf '{"ok":false,"installed":[],"error":"apt-get-not-found","missing":"%s"}\n' "${missing[*]}" >&2
  exit 2
fi

if [[ "$(id -u)" == 0 ]]; then
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${missing[@]}"
elif command -v wsl.exe >/dev/null 2>&1; then
  # WSL can launch the same distro as root without changing the user's auth files.
  distro="${WSL_DISTRO_NAME:-Ubuntu}"
  wsl.exe -d "$distro" -u root -- apt-get update -qq
  wsl.exe -d "$distro" -u root -- apt-get install -y -qq "${missing[@]}"
else
  printf '{"ok":false,"installed":[],"error":"sudo-password-required","missing":"%s"}\n' "${missing[*]}" >&2
  exit 3
fi

for command_name in curl git jq setsid ps pgrep flock; do
  command -v "$command_name" >/dev/null 2>&1 || { printf '{"ok":false,"error":"install-incomplete","missing":"%s"}\n' "$command_name" >&2; exit 4; }
done
printf '{"ok":true,"installed":"%s","message":"dependencies-installed"}\n' "${missing[*]}"
