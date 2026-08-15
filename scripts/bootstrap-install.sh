#!/usr/bin/env bash
set -euo pipefail

repository="https://github.com/yy100988-maker/wsl-codex-opencode-orchestrator.git"
ref="main"
platform=""
target_root=""

usage() {
  cat <<'EOF'
Usage: bash bootstrap-install.sh --platform <platform> [--target-root <directory>] [--repo <git-url>] [--ref <git-ref>]
EOF
}

while (($#)); do
  case "$1" in
    --platform) platform="${2:?missing platform}"; shift 2 ;;
    --target-root) target_root="${2:?missing target directory}"; shift 2 ;;
    --repo) repository="${2:?missing repository}"; shift 2 ;;
    --ref) ref="${2:?missing ref}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

[[ -n "$platform" ]] || { usage >&2; exit 64; }
command -v git >/dev/null 2>&1 || { echo 'ERROR: git is required.' >&2; exit 69; }

checkout="$(mktemp -d)"
trap 'rm -rf "$checkout"' EXIT
git clone --quiet --depth 1 --branch "$ref" "$repository" "$checkout/repository"
args=(--platform "$platform" --source "$checkout/repository")
[[ -n "$target_root" ]] && args+=(--target-root "$target_root")
bash "$checkout/repository/scripts/install-skill.sh" "${args[@]}"
