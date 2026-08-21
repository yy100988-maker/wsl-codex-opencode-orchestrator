#!/usr/bin/env bash
# V2.2 unit test: orphan process scan
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Create fake process records
mkdir -p "$TMP/root/.opencode/processes" "$TMP/root/.opencode/logs" "$TMP/root/.opencode/worktrees" "$TMP/root/.opencode/events"

cat > "$TMP/root/.opencode/processes/taskA.json" <<'EOF'
{"task_id":"taskA","pid":999999,"pgid":999999,"status":"running","cwd":"/tmp/fake","log":"/tmp/fake.log","start_time":"Mon Jan  1 00:00:00 2024","started_at":"2024-01-01T00:00:00Z"}
EOF

# Source the common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Import invoke_orphan_process_scan from supervisor-loop.sh
eval "$(sed -n '/^invoke_orphan_process_scan()/,/^}/p' "$SCRIPT_DIR/supervisor-loop.sh")"

# Run scan - taskA PID 999999 should not exist
scan_result=$(invoke_orphan_process_scan "$TMP/root/.opencode" "$TMP/root" "$TMP/root/config.json" 2>&1 || true)

# Verify orphan-recovered event was written
event_file=$(find "$TMP/root/.opencode/events" -name '*.jsonl' | head -1)
[[ -f "$event_file" ]]
grep -q "orphan-recovered" "$event_file"
grep -q "taskA" "$event_file"

echo "ok"
