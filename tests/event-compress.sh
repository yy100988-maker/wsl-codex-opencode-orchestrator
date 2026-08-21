#!/usr/bin/env bash
# V2.2 unit test: event log compression
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Create fake events directory with old and recent files
mkdir -p "$TMP/events" "$TMP/archives/events"

# Create old event file (simulate >30 days old)
echo '{"timestamp":"2025-01-01T00:00:00Z","event_type":"task-started","task_id":"old1"}' > "$TMP/events/2025-01-01.jsonl"
touch -d "60 days ago" "$TMP/events/2025-01-01.jsonl"

# Create summary-age event file (simulate 10 days old)
echo '{"timestamp":"2025-08-10T00:00:00Z","event_type":"task-started","task_id":"mid1"}' > "$TMP/events/2025-08-10.jsonl"
touch -d "10 days ago" "$TMP/events/2025-08-10.jsonl"
echo '{"timestamp":"2025-08-10T01:00:00Z","event_type":"task-finished","task_id":"mid1"}' >> "$TMP/events/2025-08-10.jsonl"
echo '{"timestamp":"2025-08-10T02:00:00Z","event_type":"gate-passed","task_id":"mid1"}' >> "$TMP/events/2025-08-10.jsonl"

# Create recent event file (within full keep days)
echo '{"timestamp":"2026-08-20T00:00:00Z","event_type":"task-started","task_id":"new1"}' > "$TMP/events/2026-08-20.jsonl"

# Source event-store and run compression
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/event-store.sh"
wsl_compress_events "$TMP/events" "$TMP/archives/events" 7 7 30

# Verify old file was archived
[[ -f "$TMP/archives/events/2025-01-01.jsonl" ]]
[[ ! -f "$TMP/events/2025-01-01.jsonl" ]]

# Verify summary file was created for mid-age file
[[ -f "$TMP/events/2025-08-10.summary.jsonl" ]]
[[ ! -f "$TMP/events/2025-08-10.jsonl" ]]

# Verify recent file was preserved
[[ -f "$TMP/events/2026-08-20.jsonl" ]]

# Verify summary contains only tracked event types
grep -q "task-started" "$TMP/events/2025-08-10.summary.jsonl"
grep -q "task-finished" "$TMP/events/2025-08-10.summary.jsonl"
grep -q "gate-passed" "$TMP/events/2025-08-10.summary.jsonl"

echo "ok"
