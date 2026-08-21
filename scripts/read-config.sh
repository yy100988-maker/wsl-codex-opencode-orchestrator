#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CONFIG_FILE="${1:-.opencode/wsl-config.json}"
WARNINGS="[]"
HAS_ERROR=0

validate_config() {
  local config="$1"
  local val

  # --- pressure_levels: level1 < level2 < level3 < level4 ---
  val=$(jq -er '.memory.pressure_levels.level1_percent // empty' "$config" 2>/dev/null || true)
  local l1="${val:-70}"
  val=$(jq -er '.memory.pressure_levels.level2_percent // empty' "$config" 2>/dev/null || true)
  local l2="${val:-80}"
  val=$(jq -er '.memory.pressure_levels.level3_percent // empty' "$config" 2>/dev/null || true)
  local l3="${val:-85}"
  val=$(jq -er '.memory.pressure_levels.level4_percent // empty' "$config" 2>/dev/null || true)
  local l4="${val:-90}"

  if ! (echo "$l1 $l2 $l3 $l4" | awk '{exit !($1 < $2 && $2 < $3 && $3 < $4)}'); then
    WARNINGS=$(echo "$WARNINGS" | jq '. + ["pressure_levels: level1 < level2 < level3 < level4 required, falling back to defaults"]')
    HAS_ERROR=1
  fi

  # --- concurrency_reduction: level1/2/3 > 0, level4 == 0 ---
  val=$(jq -er '.memory.concurrency_reduction.level1 // empty' "$config" 2>/dev/null || true)
  local r1="${val:-0.7}"
  val=$(jq -er '.memory.concurrency_reduction.level2 // empty' "$config" 2>/dev/null || true)
  local r2="${val:-0.4}"
  val=$(jq -er '.memory.concurrency_reduction.level3 // empty' "$config" 2>/dev/null || true)
  local r3="${val:-0.1}"
  val=$(jq -er '.memory.concurrency_reduction.level4 // empty' "$config" 2>/dev/null || true)
  local r4="${val:-0}"

  if ! (echo "$r1 $r2 $r3 $r4" | awk '{exit !(($1 > 0) && ($2 > 0) && ($3 > 0) && ($4 == 0))}'); then
    WARNINGS=$(echo "$WARNINGS" | jq '. + ["concurrency_reduction: level1/2/3 must be > 0 and level4 must be 0, falling back to defaults"]')
    HAS_ERROR=1
  fi

  # --- scheduler.orphan_scan_interval >= 1 ---
  val=$(jq -er '.scheduler.orphan_scan_interval // empty' "$config" 2>/dev/null || true)
  local osi="${val:-5}"
  if ! (echo "$osi" | awk '{exit !($1 >= 1)}'); then
    WARNINGS=$(echo "$WARNINGS" | jq '. + ["scheduler.orphan_scan_interval must be >= 1, falling back to default"]')
    HAS_ERROR=1
  fi

  # --- disk_recovery.threshold_mb >= 256 ---
  val=$(jq -er '.disk_recovery.threshold_mb // empty' "$config" 2>/dev/null || true)
  local tmb="${val:-1024}"
  if ! (echo "$tmb" | awk '{exit !($1 >= 256)}'); then
    WARNINGS=$(echo "$WARNINGS" | jq '. + ["disk_recovery.threshold_mb must be >= 256, falling back to default"]')
    HAS_ERROR=1
  fi

  # --- event_compress: full_keep_days < summary_start_days <= archive_after_days ---
  val=$(jq -er '.event_compress.full_keep_days // empty' "$config" 2>/dev/null || true)
  local fkd="${val:-7}"
  val=$(jq -er '.event_compress.summary_start_days // empty' "$config" 2>/dev/null || true)
  local ssd="${val:-7}"
  val=$(jq -er '.event_compress.archive_after_days // empty' "$config" 2>/dev/null || true)
  local aad="${val:-30}"
  if ! (echo "$fkd $ssd $aad" | awk '{exit !($1 < $2 && $2 <= $3)}'); then
    WARNINGS=$(echo "$WARNINGS" | jq '. + ["event_compress: full_keep_days < summary_start_days <= archive_after_days required, falling back to defaults"]')
    HAS_ERROR=1
  fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  wsl_warn "config file not found: $CONFIG_FILE, using defaults"
  RESOLVED=$(wsl_resolve_config <(echo '{}'))
  jq --argjson warnings "$WARNINGS" \
    '. + {validation_warnings: $warnings, validation_passed: true}' <<< "$RESOLVED"
  exit 0
fi

validate_config "$CONFIG_FILE"

if (( HAS_ERROR )); then
  wsl_warn "invalid config detected: $CONFIG_FILE; reverting to safe defaults"
fi

RESOLVED=$(wsl_resolve_config "$CONFIG_FILE")

jq --argjson warnings "$WARNINGS" \
  '. + {validation_warnings: $warnings, validation_passed: true}' <<< "$RESOLVED"
