#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Remove everything infra/up.sh created, including Glue tables dbt added.
# Safe to run more than once. Exits non-zero when a prefixed or tagged resource remains.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=aws_ops.sh
source "${SCRIPT_DIR}/aws_ops.sh"

usage() {
  cat <<'EOF'
usage: infra/down.sh [--dry-run] [--plan] [--region REGION]

  --dry-run   Print the AWS and Terraform calls. Does not contact AWS.
  --plan      terraform plan -destroy (read-only AWS calls). Does not delete.
  --region    AWS region. Default: the region recorded by up.sh, else us-east-1.

Deletes dbt-created Glue tables first, then terraform destroy, then a
name-prefix sweep (bucket versions, workgroup --recursive-delete, databases).
The last step lists anything still tagged project=dbt-v2-athena-e2e or named
with the harness prefix and exits non-zero if the list is not empty.
EOF
}

dry_run=0
do_plan=0
region=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --plan)
      do_plan=1
      shift
      ;;
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

if [[ "$dry_run" -eq 1 ]]; then
  e2e_need_cmd terraform
  e2e_terraform_init
  e2e_tf validate -no-color
  e2e_print_down_plan "$region"
  exit 0
fi

e2e_need_cmd aws
e2e_need_cmd jq
e2e_need_cmd terraform
e2e_have_creds || e2e_die "no AWS credentials in the environment. Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."

account="$(e2e_account_id)"
prefix="$(e2e_name_prefix "$account" "$region")"
glue_prefix="$(e2e_glue_prefix "$account" "$region")"
tag="$(e2e_project_tag)"
e2e_assert_name_prefix "$prefix"
e2e_assert_glue_prefix "$glue_prefix"

if [[ "$do_plan" -eq 1 ]]; then
  e2e_terraform_init
  e2e_tf plan -destroy -input=false -no-color -var "region=${region}"
  exit 0
fi

e2e_log "removing harness resources for ${prefix}"

# set -e is off for the destructive section so a single API error still reaches
# the verification step. Helpers refuse any name that is outside the prefix.
set +e
db=""
while IFS= read -r db; do
  [[ -n "$db" ]] || continue
  e2e_delete_tables_in_database "$db" "$glue_prefix"
done < <(e2e_glue_databases "$glue_prefix")

e2e_terraform_init
init_rc=$?
if [[ "$init_rc" -ne 0 ]]; then
  e2e_log "terraform init exited ${init_rc}"
fi

e2e_tf destroy -input=false -auto-approve -no-color -var "region=${region}"
destroy_rc=$?
if [[ "$destroy_rc" -ne 0 ]]; then
  e2e_log "terraform destroy exited ${destroy_rc}; sweeping by name before verification"
fi

e2e_empty_and_delete_bucket "$prefix"
e2e_delete_workgroup "$prefix"
while IFS= read -r db; do
  [[ -n "$db" ]] || continue
  e2e_delete_tables_in_database "$db" "$glue_prefix"
  e2e_delete_glue_database "$db" "$glue_prefix"
done < <(e2e_glue_databases "$glue_prefix")
set -e

e2e_log "verifying that no tagged or prefixed resources remain"
remaining="$(e2e_list_resources "$prefix" "$glue_prefix" "$tag")"
if [[ -n "${remaining}" ]]; then
  e2e_log "resources still present:"
  printf '%s\n' "$remaining" >&2
  exit 1
fi

state_dir="$(e2e_state_dir)"
rm -f \
  "${state_dir}/e2e.env" \
  "${state_dir}/profiles.yml" \
  "${state_dir}/outputs.json"

e2e_log "no harness resources remain in ${region}"
