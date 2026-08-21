#!/usr/bin/env bash
# V2.2 unit test: disk recovery
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Create fake .opencode directory structure
mkdir -p "$TMP/.opencode/archives" "$TMP/.opencode/worktrees" "$TMP/.opencode/events"

# Create fake old archive (>30 days)
mkdir -p "$TMP/.opencode/archives/old-task-20250101"
echo '{"task_id":"old-task"}' > "$TMP/.opencode/archives/old-task-20250101/manifest.json"
touch -d "60 days ago" "$TMP/.opencode/archives/old-task-20250101/manifest.json"

# Create recent archive (<30 days)
mkdir -p "$TMP/.opencode/archives/recent-task-20260801"
echo '{"task_id":"recent-task"}' > "$TMP/.opencode/archives/recent-task-20260801/manifest.json"

# Source worktree-manager and run disk-recovery with low threshold
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/worktree-manager.sh"

# Create config for disk recovery
cat > "$TMP/config.json" <<'EOF'
{"disk_recovery":{"enabled":true,"threshold_mb":1,"archive_max_age_days":30,"failed_archive_max_age_days":7,"delete_completed_worktrees":true}}
EOF

# Run disk recovery
invoke_disk_recovery "$TMP" "$TMP/config.json" false 2>/dev/null || true

# Verify old archive was cleaned
[[ ! -d "$TMP/.opencode/archives/old-task-20250101" ]]

# Verify recent archive was preserved
[[ -d "$TMP/.opencode/archives/recent-task-20260801" ]]

echo "ok"
