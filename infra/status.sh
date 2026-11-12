#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Show harness resources that currently exist. Exits 0 when the AWS calls succeed,
# including when the list is empty.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=aws_ops.sh
source "${SCRIPT_DIR}/aws_ops.sh"

usage() {
  cat <<'EOF'
usage: infra/status.sh [--region REGION]

Lists the bucket, Athena workgroup, Glue databases and tables, and any
resource tagged project=dbt-v2-athena-e2e for this account and region.
EOF
}

region=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || e2e_die "--region needs a value"
      region="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      e2e_die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$region" ]]; then
  region="$(e2e_region)"
fi
e2e_export_region "$region"

e2e_need_cmd aws
e2e_need_cmd jq
e2e_have_creds || e2e_die "no AWS credentials in the environment. Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."

account="$(e2e_account_id)"
prefix="$(e2e_name_prefix "$account" "$region")"
glue_prefix="$(e2e_glue_prefix "$account" "$region")"
tag="$(e2e_project_tag)"

printf 'region: %s\n' "$region"
printf 'account: %s\n' "$account"
printf 'name prefix: %s\n' "$prefix"
printf 'glue prefix: %s\n' "$glue_prefix"
printf 'tag: project=%s\n' "$tag"

state_env="$(e2e_state_dir)/e2e.env"
profiles="$(e2e_state_dir)/profiles.yml"
if [[ -f "$state_env" ]]; then
  printf 'local env: %s\n' "$state_env"
else
  printf 'local env: absent\n'
fi
if [[ -f "$profiles" ]]; then
  printf 'profiles: %s\n' "$profiles"
else
  printf 'profiles: absent\n'
fi

printf '\nresources:\n'
found="$(e2e_list_resources "$prefix" "$glue_prefix" "$tag")"
if [[ -z "$found" ]]; then
  printf '(none)\n'
else
  printf '%s\n' "$found"
fi
