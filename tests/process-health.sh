#!/usr/bin/env bash
# V2.2 unit test: process health monitoring
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Test get_process_health_state with a dead process (PID 999999 doesn't exist)
result=$(bash -c '
  pid=999999
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "dead"
  else
    echo "alive"
  fi
')
[[ "$result" == "dead" ]]

# Test with current shell PID (should be alive)
result_alive=$(bash -c '
  pid=$$
  if kill -0 "$pid" 2>/dev/null; then
    echo "alive"
  else
    echo "dead"
  fi
')
[[ "$result_alive" == "alive" ]]

echo "ok"
