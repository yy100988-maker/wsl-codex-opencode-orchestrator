#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name test
mkdir -p "$TMP/src"
printf 'a\n' > "$TMP/src/a.ts"
printf 'b\n' > "$TMP/src/b.ts"
printf 'c\n' > "$TMP/src/c.ts"
git -C "$TMP" add .
git -C "$TMP" commit -qm init
mkdir -p "$TMP/.opencode"
printf '%s\n' '{"tasks":[{"id":"A","allowed_files":["src/**"],"design_slice":"A"},{"id":"B","allowed_files":["src/b.ts"],"design_slice":"B"}]}' > "$TMP/.opencode/tasks.json"
bash "$ROOT/scripts/task-decompose.sh" "$TMP" >/dev/null
test "$(jq '.tasks | length' "$TMP/.opencode/tasks.json")" -eq 4
jq -e '.tasks | map(select(.allowed_files == ["src/b.ts"])) | length == 2' "$TMP/.opencode/tasks.json" >/dev/null
jq -e '.tasks[] | select(.decomposition_parent == "B") | .depends_on | length == 1' "$TMP/.opencode/tasks.json" >/dev/null
test -f "$TMP/.opencode/prompts/A--src-b-ts.md"
echo 'task decomposition smoke ok'
