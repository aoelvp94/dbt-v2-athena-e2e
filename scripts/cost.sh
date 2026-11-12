#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Estimate Athena cost from dbt artifacts or GetQueryExecution JSON.
# Athena is US$5 per TB scanned (10^12 bytes). Each billed query is rounded up
# to the next MiB, with a 10 MiB minimum. Failed queries and DDL are treated as free.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_BYTES=10485760
TB_BYTES=1000000000000
USD_PER_TB=5

usage() {
  cat <<'EOF'
usage: scripts/cost.sh [--self-test] [json-file ...]

Reads dbt run_results JSON and Athena GetQueryExecution JSON. Prints one line:
  bytes_scanned billed_bytes estimated_cost_usd query_count method
EOF
}

billed_for_query() {
  local status="$1"
  local bytes="$2"
  local statement="$3"
  local upper
  upper="$(printf '%s' "$statement" | tr '[:lower:]' '[:upper:]')"
  if [[ "$status" != "success" ]]; then
    printf '0\n'
    return
  fi
  case "$upper" in
    DDL)
      printf '0\n'
      return
      ;;
  esac
  if [[ "$bytes" -lt "$MIN_BYTES" ]]; then
    printf '%s\n' "$MIN_BYTES"
    return
  fi
  local remainder rounded
  remainder=$((bytes % 1048576))
  if [[ "$remainder" -eq 0 ]]; then
    printf '%s\n' "$bytes"
  else
    rounded=$(((bytes / 1048576 + 1) * 1048576))
    printf '%s\n' "$rounded"
  fi
}

estimate_files() {
  local scanned=0
  local billed=0
  local counted=0
  local seen="|"
  local file status bytes qid statement bill

  for file in "$@"; do
    [[ -f "$file" ]] || continue
    while IFS=$'\t' read -r status bytes qid statement; do
      [[ -n "$status" ]] || continue
      bytes="${bytes:-0}"
      statement="${statement:-UNKNOWN}"
      if [[ -n "$qid" && "$seen" == *"|${qid}|"* ]]; then
        continue
      fi
      if [[ -n "$qid" ]]; then
        seen="${seen}${qid}|"
      fi
      bill="$(billed_for_query "$status" "$bytes" "$statement")"
      if [[ "$bill" -gt 0 ]]; then
        scanned=$((scanned + bytes))
        billed=$((billed + bill))
        counted=$((counted + 1))
      fi
    done < <(jq -rf "${SCRIPT_DIR}/cost.jq" "$file")
  done

  local cost
  cost="$(awk -v billed="$billed" -v tb="$TB_BYTES" -v rate="$USD_PER_TB" 'BEGIN { printf "%.8f", (billed / tb) * rate }')"
  printf '%s %s %s %s artifact\n' "$scanned" "$billed" "$cost" "$counted"
}

self_test() {
  local dir
  dir="$(mktemp -d)"
  cat >"${dir}/one.json" <<'EOF'
{
  "results": [
    {"status": "success", "adapter_response": {"data_scanned_in_bytes": 100, "query_id": "q1"}},
    {"status": "success", "adapter_response": {"data_scanned_in_bytes": 20971520, "query_id": "q2", "statement_type": "DML"}},
    {"status": "error", "adapter_response": {"data_scanned_in_bytes": 5000000000, "query_id": "q3"}},
    {"status": "success", "adapter_response": {"data_scanned_in_bytes": 1000, "query_id": "q4", "statement_type": "DDL"}}
  ]
}
EOF
  cat >"${dir}/two.json" <<'EOF'
{
  "QueryExecution": {
    "QueryExecutionId": "q2",
    "Status": {"State": "SUCCEEDED"},
    "Statistics": {"DataScannedInBytes": 20971520},
    "StatementType": "DML"
  }
}
EOF
  local scanned billed cost count method
  read -r scanned billed cost count method < <(estimate_files "${dir}/one.json" "${dir}/two.json")
  rm -rf "$dir"
  local expected_billed=31457280
  if [[ "$billed" != "$expected_billed" || "$count" != "2" || "$scanned" != "20971620" ]]; then
    printf 'cost self-test failed: scanned=%s billed=%s count=%s cost=%s\n' \
      "$scanned" "$billed" "$count" "$cost" >&2
    exit 1
  fi
  printf 'cost self-test ok: scanned=%s billed=%s usd=%s queries=%s method=%s\n' \
    "$scanned" "$billed" "$cost" "$count" "$method"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
  fi
  estimate_files "$@"
fi
