#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q; git -C "$TMP" config user.email test@example.com; git -C "$TMP" config user.name test; printf 'ok\n' > "$TMP/README.md"; git -C "$TMP" add .; git -C "$TMP" commit -qm init
mkdir -p "$TMP/.opencode"; printf '{"tasks":[{"id":"smoke","allowed_files":["README.md"],"test_command":"test -f README.md","status":"pending"}]}' > "$TMP/.opencode/tasks.json"
printf '{"wsl":{"project_root":"%s"},"models":{"implementation":"x","fallback":"y","validation":"x"},"scheduler":{"max_concurrent_agents":1},"memory":{"windows_stop_admission_percent":88,"windows_critical_percent":90,"windows_reserve_mb":1,"wsl_stop_admission_percent":99}}\n' "$TMP" > "$TMP/config.json"
"$ROOT/scripts/worktree-manager.sh" create "$TMP" smoke >/dev/null
test -d "$TMP/.opencode/worktrees/smoke"
printf '{"completed":true}\n' > "$TMP/.opencode/worktrees/smoke/.opencode-handoff.json"
"$ROOT/scripts/gate-runner.sh" "$TMP" smoke "$TMP/.opencode/worktrees/smoke" >/dev/null
jq -e '.passed == true' "$TMP/.opencode/gates/smoke/result.json" >/dev/null
"$ROOT/scripts/worktree-manager.sh" remove "$TMP" smoke
echo "smoke ok"
