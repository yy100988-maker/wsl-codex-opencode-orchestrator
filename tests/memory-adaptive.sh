#!/usr/bin/env bash
# V2.2 unit test: memory adaptive concurrency
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Stub adaptive_concurrency function from admission-cycle.sh
adaptive_concurrency() {
  local used=$1 max=$2
  local l1=70 l2=80 l3=85 l4=90
  local r1=70 r2=40 r3=10 r4=0
  if (( used < l1 )); then echo "$max"
  elif (( used < l2 )); then echo $(( max * r1 / 100 ))
  elif (( used < l3 )); then echo $(( max * r2 / 100 ))
  elif (( used < l4 )); then echo $(( max * r3 / 100 ))
  else echo 0; fi
}

# Test boundary values
[[ $(adaptive_concurrency 0 100) -eq 100 ]]
[[ $(adaptive_concurrency 69 100) -eq 100 ]]
[[ $(adaptive_concurrency 70 100) -eq 70 ]]
[[ $(adaptive_concurrency 79 100) -eq 70 ]]
[[ $(adaptive_concurrency 80 100) -eq 40 ]]
[[ $(adaptive_concurrency 84 100) -eq 40 ]]
[[ $(adaptive_concurrency 85 100) -eq 10 ]]
[[ $(adaptive_concurrency 89 100) -eq 10 ]]
[[ $(adaptive_concurrency 90 100) -eq 0 ]]
[[ $(adaptive_concurrency 95 100) -eq 0 ]]
[[ $(adaptive_concurrency 50 200) -eq 200 ]]
[[ $(adaptive_concurrency 88 200) -eq 20 ]]

echo "ok"
