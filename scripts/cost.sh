#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Estimate Athena cost from Athena GetQueryExecution JSON or dbt run_results.
# GetQueryExecution is the primary source: run_results does not carry
# data_scanned_in_bytes. Athena is US$5 per TB scanned (10^12 bytes). Each
# successful DML query is rounded up to the next MiB, with a 10 MiB minimum.
# Failed queries and DDL are not billed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_BYTES=10485760
TB_BYTES=1000000000000
USD_PER_TB=5

usage() {
  cat <<'EOF'
usage: scripts/cost.sh [--self-test] [json-file ...]
       scripts/cost.sh --from-work-group NAME --since-epoch EPOCH --cache-dir DIR

Reads dbt run_results JSON and Athena GetQueryExecution JSON. Prints one line:
  bytes_scanned billed_bytes estimated_cost_usd query_count method

--from-work-group lists query executions in that workgroup since --since-epoch
(list-query-executions, newest first, following NextToken) and calls
GetQueryExecution for each one still inside the window. That is the primary
source. The line's method is athena-api. Exit status is non-zero when the
Athena calls fail, so the caller can fall back to run_results JSON.
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

epoch_of() {
  local raw="$1"
  local whole
  if [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    whole="${raw%%.*}"
    printf '%s\n' "$whole"
    return 0
  fi
  date -u -d "$raw" +%s 2>/dev/null || printf '0\n'
}

# List the workgroup over the run window and write one GetQueryExecution JSON
# per query under cache_dir/qe-<id>.json. Newest executions come first, so the
# walk stops at the first query submitted before since_epoch.
collect_workgroup() {
  local work_group="$1"
  local since_epoch="$2"
  local cache_dir="$3"
  local token="" page qid qjson submitted sub_epoch stop=0
  local -a ids=()
  local -a args=()
  mkdir -p "$cache_dir"
  : >"${cache_dir}/query-ids.txt"
  while [[ "$stop" -eq 0 ]]; do
    args=(aws athena list-query-executions --work-group "$work_group" --max-results 50 --output json)
    if [[ -n "$token" ]]; then
      args+=(--next-token "$token")
    fi
    page="${cache_dir}/list-page.json"
    if ! "${args[@]}" >"$page" 2>>"${cache_dir}/athena-list.err"; then
      echo "error: aws athena list-query-executions failed for ${work_group}" >&2
      return 1
    fi
    mapfile -t ids < <(jq -r '.QueryExecutionIds[]?' "$page")
    if [[ ${#ids[@]} -eq 0 ]]; then
      break
    fi
    for qid in "${ids[@]}"; do
      [[ -n "$qid" && "$qid" != "None" ]] || continue
      printf '%s\n' "$qid" >>"${cache_dir}/query-ids.txt"
      qjson="${cache_dir}/qe-${qid}.json"
      if ! aws athena get-query-execution --query-execution-id "$qid" --output json >"$qjson" 2>>"${cache_dir}/athena-list.err"; then
        rm -f "$qjson"
        continue
      fi
      submitted="$(jq -r '.QueryExecution.Status.SubmissionDateTime // empty' "$qjson")"
      sub_epoch="$(epoch_of "$submitted")"
      if [[ "$sub_epoch" -gt 0 && "$sub_epoch" -lt "$since_epoch" ]]; then
        rm -f "$qjson"
        stop=1
        break
      fi
    done
    token="$(jq -r '.NextToken // empty' "$page")"
    if [[ -z "$token" ]]; then
      break
    fi
  done
  rm -f "$page"
}

estimate_files() {
  local method="$1"
  shift
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
  printf '%s %s %s %s %s\n' "$scanned" "$billed" "$cost" "$counted" "$method"
}

estimate_workgroup() {
  local work_group="$1"
  local since_epoch="$2"
  local cache_dir="$3"
  local -a api_files=()
  collect_workgroup "$work_group" "$since_epoch" "$cache_dir"
  shopt -s nullglob
  api_files=("${cache_dir}"/qe-*.json)
  shopt -u nullglob
  if [[ ${#api_files[@]} -eq 0 ]]; then
    estimate_files athena-api
  else
    estimate_files athena-api "${api_files[@]}"
  fi
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
  read -r scanned billed cost count method < <(estimate_files artifact "${dir}/one.json" "${dir}/two.json")
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
  if [[ "${1:-}" == "--from-work-group" ]]; then
    work_group=""
    since_epoch=""
    cache_dir=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --since-epoch)
          [[ $# -ge 2 ]] || { echo "error: --since-epoch needs a value" >&2; exit 1; }
          since_epoch="$2"
          shift 2
          ;;
        --cache-dir)
          [[ $# -ge 2 ]] || { echo "error: --cache-dir needs a path" >&2; exit 1; }
          cache_dir="$2"
          shift 2
          ;;
        *)
          if [[ -z "$work_group" ]]; then
            work_group="$1"
            shift
          else
            echo "error: unexpected argument: $1" >&2
            exit 1
          fi
          ;;
      esac
    done
    if [[ -z "$work_group" || -z "$since_epoch" || -z "$cache_dir" ]]; then
      echo "error: --from-work-group needs NAME --since-epoch EPOCH --cache-dir DIR" >&2
      exit 1
    fi
    estimate_workgroup "$work_group" "$since_epoch" "$cache_dir"
    exit 0
  fi
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
  fi
  estimate_files artifact "$@"
fi
