#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM=""
TARGET_ROOT=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: bash scripts/install-skill.sh --platform <platform> [--source <directory>] [--target-root <directory>] [--dry-run]

Platforms: codex, claude-code, opencode, trae, qoder, grok-cli, workbuddy
EOF
}

while (($#)); do
  case "$1" in
    --platform) PLATFORM="${2:?missing platform}"; shift 2 ;;
    --source) SOURCE_ROOT="${2:?missing source directory}"; shift 2 ;;
    --target-root) TARGET_ROOT="${2:?missing target directory}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

case "$PLATFORM" in
  codex|claude-code|opencode) install_mode="native-skill" ;;
  trae|qoder|grok-cli|workbuddy) install_mode="external-adapter" ;;
  *) printf 'ERROR: unsupported or missing platform: %s\n' "$PLATFORM" >&2; usage >&2; exit 64 ;;
esac

[[ -f "$SOURCE_ROOT/SKILL.md" ]] || { printf 'ERROR: source does not contain SKILL.md: %s\n' "$SOURCE_ROOT" >&2; exit 66; }

if [[ -z "$TARGET_ROOT" ]]; then
  case "$PLATFORM" in
    codex) TARGET_ROOT="${CODEX_HOME:-$HOME/.codex}/skills" ;;
    claude-code) TARGET_ROOT="${CLAUDE_HOME:-$HOME/.claude}/skills" ;;
    opencode) TARGET_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
    *) TARGET_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/wsl-codex-opencode-orchestrator/$PLATFORM" ;;
  esac
fi

destination="$TARGET_ROOT/wsl-codex-opencode-orchestrator"
if [[ "$DRY_RUN" == true ]]; then
  jq -cn --arg platform "$PLATFORM" --arg source "$SOURCE_ROOT" --arg destination "$destination" --arg mode "$install_mode" \
    '{ok:true,dry_run:true,platform:$platform,source:$source,destination:$destination,mode:$mode}'
  exit 0
fi

mkdir -p "$TARGET_ROOT"
staging="$TARGET_ROOT/.wsl-codex-opencode-orchestrator.incoming.$$"
backup="$TARGET_ROOT/.wsl-codex-opencode-orchestrator.backup.$$"
trap 'rm -rf "$staging" "$backup"' EXIT
mkdir "$staging"

for item in SKILL.md README.md 使用说明.md 详细设计文档.md CONTRIBUTING.md SECURITY.md docs scripts tests; do
  [[ -e "$SOURCE_ROOT/$item" ]] && cp -R "$SOURCE_ROOT/$item" "$staging/"
done
printf '%s\n' "$PLATFORM" > "$staging/.platform-profile"
jq -cn --arg platform "$PLATFORM" --arg mode "$install_mode" \
  '{schema_version:1,platform:$platform,mode:$mode}' > "$staging/platform-profile.json"

if [[ -e "$destination" ]]; then
  mv "$destination" "$backup"
fi
mv "$staging" "$destination"
rm -rf "$backup"
trap - EXIT

jq -cn --arg platform "$PLATFORM" --arg destination "$destination" --arg mode "$install_mode" \
  '{ok:true,platform:$platform,destination:$destination,entry:($destination + "/SKILL.md"),mode:$mode}'
