#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Offline and live checks for the Athena dbt v2 stack.
# Live checks need infra/up.sh and AWS credentials already in the environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ROOT}/project"
offline_only=0
binary_path=""

usage() {
  cat <<'EOF'
usage: scripts/run_e2e.sh [--offline] [--binary PATH]

  --offline   parse, ls, and init only. No AWS calls.
  --binary    dbt executable. Default: .cache/dbt-v2-athena-e2e/dist/dbt, else PATH.

Writes results/<UTC timestamp>/summary.md and summary.json.
Each check is mapped to the pull request it exercises.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) offline_only=1; shift ;;
    --binary)
      [[ $# -ge 2 ]] || { echo "error: --binary needs a path" >&2; exit 1; }
      binary_path="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

export DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true
export DBT_SEND_ANONYMOUS_USAGE_STATS=false

if [[ -z "$binary_path" && -n "${DBT_BIN:-}" ]]; then
  binary_path="$DBT_BIN"
fi
if [[ -z "$binary_path" && -x "${ROOT}/.cache/dbt-v2-athena-e2e/dist/dbt" ]]; then
  binary_path="${ROOT}/.cache/dbt-v2-athena-e2e/dist/dbt"
fi
if [[ -z "$binary_path" ]]; then
  binary_path="$(command -v dbt || true)"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS="${ROOT}/results/${stamp}"
mkdir -p "$RESULTS"
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"

checks_json='[]'
failed=0

record() {
  local name="$1" status="$2" prs="$3" seconds="$4" detail="$5"
  checks_json="$(jq -c \
    --arg name "$name" \
    --arg status "$status" \
    --arg prs "$prs" \
    --argjson seconds "$seconds" \
    --arg detail "$detail" \
    '. += [{name: $name, status: $status, prs: ($prs | split(",") | map(tonumber)), seconds: $seconds, detail: $detail}]' \
    <<<"$checks_json")"
  printf '%-22s %-8s %ss  %s\n' "$name" "$status" "$seconds" "$detail"
  if [[ "$status" == "failed" ]]; then
    failed=$((failed + 1))
  fi
}

run_logged() {
  local name="$1"
  shift
  local log="${RESULTS}/${name}.log"
  local start end status
  start="$(date +%s)"
  set +e
  "$@" >"$log" 2>&1
  status=$?
  set -e
  end="$(date +%s)"
  RUN_STATUS="$status"
  RUN_SECONDS="$((end - start))"
  if [[ -f "${PROJECT}/target/run_results.json" ]]; then
    cp "${PROJECT}/target/run_results.json" "${RESULTS}/run_results_${name}.json"
  fi
}

require_binary() {
  if [[ -z "$binary_path" || ! -x "$binary_path" ]]; then
    return 1
  fi
  return 0
}

profiles_dir=""
if [[ -f "${ROOT}/infra/.state/profiles.yml" ]]; then
  profiles_dir="${ROOT}/infra/.state"
else
  profiles_dir="${RESULTS}/profiles"
  mkdir -p "$profiles_dir"
  cp "${ROOT}/infra/profiles.yml.example" "${profiles_dir}/profiles.yml"
fi

COMMON=(
  --project-dir "$PROJECT"
  --profiles-dir "$profiles_dir"
  --no-send-anonymous-usage-stats
)

dbt() {
  "$binary_path" "$@"
}

check_parse() {
  local name="parse" prs="16274,16367,16368,16369"
  if ! require_binary; then
    record "$name" failed "$prs" 0 "dbt binary not found; run scripts/build_dbt.sh or pass --binary"
    return
  fi
  run_logged "$name" dbt parse "${COMMON[@]}"
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt parse exited ${RUN_STATUS}; see ${name}.log"
    return
  fi
  if grep -E -q 'UnusedConfigKey|SerializationError|todo!\("Athena"\)' "${RESULTS}/${name}.log"; then
    record "$name" failed "$prs" "$RUN_SECONDS" "parse log still reports an Athena config or todo failure"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "parse accepted the Athena profile, macros, and model configs"
}

check_ls() {
  local name="ls" prs="16367,16369"
  if ! require_binary; then
    record "$name" failed "$prs" 0 "dbt binary not found"
    return
  fi
  run_logged "$name" dbt ls "${COMMON[@]}"
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt ls exited ${RUN_STATUS}"
    return
  fi
  local missing="" model
  for model in stg_orders orders_hive orders_iceberg orders_incremental_hive orders_incremental_iceberg raw_orders; do
    if ! grep -q "$model" "${RESULTS}/${name}.log"; then
      missing="${missing} ${model}"
    fi
  done
  if [[ -n "$missing" ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "ls output missing:${missing}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "ls listed the seeds and models"
}

check_init() {
  local name="init" prs="16375,16274"
  if ! require_binary; then
    record "$name" failed "$prs" 0 "dbt binary not found"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  run_logged "$name" bash -c "
    set -euo pipefail
    cd '$tmp'
    '$binary_path' init --project-name athena_e2e_init_probe --skip-profile-setup --no-send-anonymous-usage-stats
    test -f athena_e2e_init_probe/dbt_project.yml
  "
  rm -rf "$tmp"
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "headless init exited ${RUN_STATUS}. The Athena wizard itself is interactive; this check is dbt init --skip-profile-setup."
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "dbt init --skip-profile-setup created a project without prompting"
}

check_debug() {
  local name="debug" prs="16365,16274"
  run_logged "$name" dbt debug "${COMMON[@]}"
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt debug exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "driver loaded and the connection test finished"
}

check_seed() {
  local name="seed" prs="16369,16376"
  run_logged "$name" dbt seed "${COMMON[@]}"
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt seed exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "seeds loaded"
}

check_run() {
  local name="run" prs="16368,16369,16374,16376"
  run_logged "$name" dbt run "${COMMON[@]}" --vars '{include_late_order: false}'
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "first dbt run exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "view, hive table, iceberg table, and both incrementals built"
}

check_incremental_branch() {
  local name="incremental_branch" prs="16374"
  run_logged "$name" dbt compile "${COMMON[@]}" --select orders_incremental_iceberg orders_incremental_hive
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "compile of incremental models exited ${RUN_STATUS}"
    return
  fi
  if ! grep -R --include='*.sql' -q -F 'e2e_is_incremental' "${PROJECT}/target"; then
    record "$name" failed "$prs" "$RUN_SECONDS" "compiled SQL has no e2e_is_incremental marker; is_incremental() was false"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "second compile rendered the is_incremental() branch"
}

check_run_again() {
  local name="run_again" prs="16374,16376"
  run_logged "$name" dbt run "${COMMON[@]}" --vars '{include_late_order: true}' --select orders_incremental_hive orders_incremental_iceberg
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "second dbt run exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "incremental models ran again, including the Iceberg merge"
}

check_test() {
  local name="test" prs="16370"
  run_logged "$name" dbt test "${COMMON[@]}" --vars '{include_late_order: true}'
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt test exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "schema tests, the late-order check, and the unit test passed"
}

check_show_inline() {
  local name="show_inline" prs="16374"
  run_logged "$name" dbt show "${COMMON[@]}" --inline 'select 1 as n' --limit 5
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt show --inline exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "dbt show --inline returned"
}

check_show_model() {
  local name="show_model" prs="16374"
  run_logged "$name" dbt show "${COMMON[@]}" --select orders_incremental_iceberg --limit 5
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt show on the incremental model exited ${RUN_STATUS}"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "dbt show returned rows for the Iceberg merge model"
}

check_catalog() {
  local name="compile_catalog" prs="16369"
  run_logged "$name" dbt compile "${COMMON[@]}" --write-catalog
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "dbt compile --write-catalog exited ${RUN_STATUS}"
    return
  fi
  local catalog="${PROJECT}/target/catalog.json"
  if [[ ! -s "$catalog" ]]; then
    record "$name" failed "$prs" "$RUN_SECONDS" "catalog.json is missing or empty"
    return
  fi
  cp "$catalog" "${RESULTS}/catalog.json"
  if ! grep -q "stg_orders" "$catalog"; then
    record "$name" failed "$prs" "$RUN_SECONDS" "catalog.json does not mention stg_orders"
    return
  fi
  record "$name" passed "$prs" "$RUN_SECONDS" "compile --write-catalog wrote a catalog that includes stg_orders"
}

skip_live() {
  local name="$1" prs="$2" why="$3"
  record "$name" skipped "$prs" 0 "$why"
}

check_parse
check_ls
check_init

if [[ "$offline_only" -eq 1 ]]; then
  why="skipped by --offline"
  skip_live debug "16365,16274" "$why"
  skip_live seed "16369,16376" "$why"
  skip_live run "16368,16369,16374,16376" "$why"
  skip_live incremental_branch "16374" "$why"
  skip_live run_again "16374,16376" "$why"
  skip_live test "16370" "$why"
  skip_live show_inline "16374" "$why"
  skip_live show_model "16374" "$why"
  skip_live compile_catalog "16369" "$why"
elif [[ ! -f "${ROOT}/infra/.state/profiles.yml" ]]; then
  why="infra/.state/profiles.yml is missing; run infra/up.sh"
  record debug failed "16365,16274" 0 "$why"
  record seed failed "16369,16376" 0 "$why"
  record run failed "16368,16369,16374,16376" 0 "$why"
  record incremental_branch failed "16374" 0 "$why"
  record run_again failed "16374,16376" 0 "$why"
  record test failed "16370" 0 "$why"
  record show_inline failed "16374" 0 "$why"
  record show_model failed "16374" 0 "$why"
  record compile_catalog failed "16369" 0 "$why"
elif ! require_binary; then
  why="dbt binary not found"
  record debug failed "16365,16274" 0 "$why"
  record seed failed "16369,16376" 0 "$why"
  record run failed "16368,16369,16374,16376" 0 "$why"
  record incremental_branch failed "16374" 0 "$why"
  record run_again failed "16374,16376" 0 "$why"
  record test failed "16370" 0 "$why"
  record show_inline failed "16374" 0 "$why"
  record show_model failed "16374" 0 "$why"
  record compile_catalog failed "16369" 0 "$why"
else
  check_debug
  check_seed
  check_run
  check_incremental_branch
  check_run_again
  check_test
  check_show_inline
  check_show_model
  check_catalog
fi

scanned=0
billed=0
cost="0.00000000"
queries=0
method="none"
artifact_files=()
shopt -s nullglob
artifact_files=("${RESULTS}"/run_results_*.json)
shopt -u nullglob
if [[ ${#artifact_files[@]} -gt 0 ]]; then
  read -r scanned billed cost queries method < <("${SCRIPT_DIR}/cost.sh" "${artifact_files[@]}")
fi

api_note=""
work_group=""
if [[ -f "${ROOT}/infra/.state/e2e.env" ]]; then
  work_group="$(sed -n 's/^E2E_WORK_GROUP=//p' "${ROOT}/infra/.state/e2e.env" | tail -n 1)"
fi
if [[ "$offline_only" -eq 0 && -n "$work_group" && -n "${AWS_ACCESS_KEY_ID:-}${AWS_PROFILE:-}" ]] && command -v aws >/dev/null 2>&1; then
  ids_file="${RESULTS}/query-ids.txt"
  if aws athena list-query-executions --work-group "$work_group" --max-results 50 --output text --query 'QueryExecutionIds' >"$ids_file" 2>"${RESULTS}/athena-list.err"; then
    : >"${RESULTS}/athena-queries.ndjson"
    kept=0
    # list-query-executions prints ids on one line, tab or space separated, newest first.
    for qid in $(tr '\t' ' ' <"$ids_file"); do
      [[ -n "$qid" && "$qid" != "None" ]] || continue
      qjson="${RESULTS}/qe-${qid}.json"
      if ! aws athena get-query-execution --query-execution-id "$qid" --output json >"$qjson" 2>>"${RESULTS}/athena-list.err"; then
        rm -f "$qjson"
        continue
      fi
      submitted="$(jq -r '.QueryExecution.Status.SubmissionDateTime' "$qjson")"
      sub_epoch="$(date -u -d "$submitted" +%s 2>/dev/null || echo 0)"
      if [[ "$sub_epoch" -lt "$START_EPOCH" ]]; then
        rm -f "$qjson"
        break
      fi
      kept=$((kept + 1))
      if [[ "$kept" -ge 80 ]]; then
        break
      fi
    done
    shopt -s nullglob
    api_files=("${RESULTS}"/qe-*.json)
    shopt -u nullglob
    if [[ ${#api_files[@]} -gt 0 ]]; then
      read -r scanned billed cost queries method < <("${SCRIPT_DIR}/cost.sh" "${api_files[@]}")
      method="athena-api"
      api_note="Athena GetQueryExecution for workgroup ${work_group} since ${START_ISO}."
    fi
  else
    api_note="Athena query listing failed; cost uses dbt artifacts when they carry byte counts."
  fi
fi

if [[ "$method" == "artifact" && "$queries" -eq 0 ]]; then
  method="none"
  api_note="${api_note} No query byte counts were found in run_results. A driver without statistics metadata leaves bytes at 0, and DDL is not billed."
fi

finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg started_at "$START_ISO" \
  --arg finished_at "$finished" \
  --arg binary "${binary_path:-}" \
  --arg profiles "$profiles_dir" \
  --argjson checks "$checks_json" \
  --argjson failed "$failed" \
  --argjson bytes_scanned "$scanned" \
  --argjson billed_bytes "$billed" \
  --arg cost "$cost" \
  --argjson queries "$queries" \
  --arg method "$method" \
  --arg note "$api_note" \
  '{
    started_at: $started_at,
    finished_at: $finished_at,
    binary: $binary,
    profiles_dir: $profiles,
    failed_checks: $failed,
    checks: $checks,
    bytes_scanned: $bytes_scanned,
    billed_bytes: $billed_bytes,
    estimated_cost_usd: $cost,
    billed_query_count: $queries,
    estimate_method: $method,
    estimate_note: $note,
    pricing: {
      usd_per_terabyte: 5,
      terabyte_bytes: 1000000000000,
      minimum_bytes_per_query: 10485760,
      ddl_and_failed_queries: "not billed in this estimate"
    }
  }' >"${RESULTS}/summary.json"

{
  echo "# dbt v2 Athena e2e ${stamp}"
  echo
  echo "Binary: \`${binary_path:-not found}\`"
  echo
  echo "Profiles: \`${profiles_dir}\`"
  echo
  echo "| Check | Result | Pull requests | Seconds | Detail |"
  echo "| --- | --- | --- | --- | --- |"
  jq -r '.checks[] | "| \(.name) | \(.status) | \(.prs | join(", ")) | \(.seconds) | \(.detail) |"' "${RESULTS}/summary.json"
  echo
  echo "Bytes scanned (reported): ${scanned}"
  echo
  echo "Billed bytes (10 MiB minimum per successful non-DDL query, rounded up to 1 MiB): ${billed}"
  echo
  echo "Estimated cost at US\$5 per TB (10^12 bytes): US\$${cost}"
  echo
  echo "Estimate method: ${method}. ${api_note}"
  echo
  echo "Athena bills at least 10 MB per query, so a few dozen tiny statements still land under a cent. The workgroup cap is 1 GB per query."
} >"${RESULTS}/summary.md"

echo "summary: ${RESULTS}/summary.md"
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
