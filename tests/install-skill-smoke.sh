#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for platform in codex claude-code opencode trae qoder grok-cli workbuddy; do
  target="$TMP/$platform"
  output="$(bash "$ROOT/scripts/install-skill.sh" --platform "$platform" --source "$ROOT" --target-root "$target")"
  jq -e --arg platform "$platform" '.ok == true and .platform == $platform' <<<"$output" >/dev/null
  installed="$target/wsl-codex-opencode-orchestrator"
  test -f "$installed/SKILL.md"
  test "$(cat "$installed/.platform-profile")" = "$platform"
  jq -e --arg platform "$platform" '.schema_version == 1 and .platform == $platform' "$installed/platform-profile.json" >/dev/null
done

dry_run="$(bash "$ROOT/scripts/install-skill.sh" --platform codex --source "$ROOT" --target-root "$TMP/dry-run" --dry-run)"
jq -e '.ok == true and .dry_run == true and .mode == "native-skill"' <<<"$dry_run" >/dev/null
test ! -e "$TMP/dry-run/wsl-codex-opencode-orchestrator"

fixture="$TMP/fixture"
mkdir -p "$fixture/scripts"
cp "$ROOT/SKILL.md" "$fixture/SKILL.md"
cp "$ROOT/scripts/install-skill.sh" "$ROOT/scripts/bootstrap-install.sh" "$fixture/scripts/"
git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.com
git -C "$fixture" config user.name test
git -C "$fixture" add .
git -C "$fixture" commit -qm init
git -C "$fixture" branch -M main
bash "$ROOT/scripts/bootstrap-install.sh" --platform opencode --repo "file://$fixture" --ref main --target-root "$TMP/bootstrap" >/dev/null
test -f "$TMP/bootstrap/wsl-codex-opencode-orchestrator/SKILL.md"

echo "install smoke ok"
