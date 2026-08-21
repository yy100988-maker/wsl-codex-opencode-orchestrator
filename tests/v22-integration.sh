#!/usr/bin/env bash
# V2.2 integration test: end-to-end workflow
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/project"
mkdir -p "$ROOT/.opencode/events" "$ROOT/.opencode/logs" "$ROOT/.opencode/processes" "$ROOT/.opencode/worktrees" "$ROOT/.opencode/archives" "$ROOT/.opencode/metrics"

# Initialize git repo
cd "$ROOT"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "# Test" > README.md
git add . && git commit -qm "init"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Test 1: State initialization
wsl_ensure_state_dirs "$ROOT/.opencode/orchestrator-state.json"
[[ -f "$ROOT/.opencode/orchestrator-state.json" ]]
[[ -f "$ROOT/.opencode/leases.json" ]]

# Test 2: Event writing
wsl_append_event "$ROOT/.opencode/orchestrator-state.json" "test-event" "task1" '{"key":"value"}'
event_file=$(find "$ROOT/.opencode/events" -name '*.jsonl' | head -1)
[[ -f "$event_file" ]]
grep -q "test-event" "$event_file"

# Test 3: Config validation (read-config.sh)
cat > "$ROOT/.opencode/wsl-config.json" <<'CONF'
{"memory":{"pressure_levels":{"level1_percent":70,"level2_percent":80,"level3_percent":85,"level4_percent":90},"concurrency_reduction":{"level1":0.7,"level2":0.4,"level3":0.1,"level4":0}},"disk_recovery":{"threshold_mb":256},"event_compress":{"full_keep_days":7,"summary_start_days":7,"archive_after_days":30}}
CONF
if bash "$SCRIPT_DIR/read-config.sh" "$ROOT/.opencode/wsl-config.json" >/dev/null 2>&1; then
  config_ok=true
else
  config_ok=false
fi
[[ "$config_ok" == "true" ]]

echo "ok"
