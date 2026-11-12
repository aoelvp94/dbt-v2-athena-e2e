# SPDX-License-Identifier: Apache-2.0
# Shared helpers for infra/up.sh, infra/down.sh, and infra/status.sh.
# Keep the naming formula aligned with infra/terraform/locals.tf.

# shellcheck shell=bash

e2e_infra_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

e2e_repo_root() {
  cd "$(e2e_infra_dir)/.." && pwd
}

e2e_tf_dir() {
  printf '%s\n' "$(e2e_infra_dir)/terraform"
}

e2e_state_dir() {
  printf '%s\n' "$(e2e_infra_dir)/.state"
}

e2e_log() {
  printf '%s\n' "$*" >&2
}

e2e_die() {
  e2e_log "error: $*"
  exit 1
}

e2e_need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || e2e_die "required command not found: ${cmd}"
}

# True when the process has static keys, a named profile, or a web identity.
# Ambient instance credentials also count: the AWS CLI will use them.
e2e_have_creds() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${AWS_PROFILE:-}" || -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" || -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]]; then
    return 0
  fi
  return 1
}

e2e_region() {
  if [[ -n "${E2E_REGION:-}" ]]; then
    printf '%s\n' "$E2E_REGION"
    return
  fi
  if [[ -n "${AWS_REGION:-}" ]]; then
    printf '%s\n' "$AWS_REGION"
    return
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    printf '%s\n' "$AWS_DEFAULT_REGION"
    return
  fi
  local env_file saved
  env_file="$(e2e_state_dir)/e2e.env"
  if [[ -f "$env_file" ]]; then
    saved="$(sed -n 's/^E2E_REGION=//p' "$env_file" | tail -n 1 | tr -d '"')"
    if [[ -n "$saved" ]]; then
      printf '%s\n' "$saved"
      return
    fi
  fi
  printf '%s\n' "us-east-1"
}

e2e_export_region() {
  local region="$1"
  export AWS_REGION="$region"
  export AWS_DEFAULT_REGION="$region"
  export TF_VAR_region="$region"
  export E2E_REGION="$region"
}

e2e_account_id() {
  e2e_need_cmd aws
  local account
  account="$(aws sts get-caller-identity --query Account --output text)"
  [[ "$account" =~ ^[0-9]{12}$ ]] || e2e_die "STS account id is not 12 digits: ${account}"
  printf '%s\n' "$account"
}

# aoelvp94-dbt-athena-test-<account-id>-<region>
e2e_name_prefix() {
  local account="$1"
  local region="$2"
  printf '%s\n' "aoelvp94-dbt-athena-test-${account}-${region}"
}

# aoelvp94_dbt_athena_test_<account-id>_<region_with_underscores>
e2e_glue_prefix() {
  local account="$1"
  local region="$2"
  local region_us="${region//-/_}"
  printf '%s\n' "aoelvp94_dbt_athena_test_${account}_${region_us}"
}

e2e_assert_name_prefix() {
  local prefix="$1"
  [[ "$prefix" =~ ^aoelvp94-dbt-athena-test-[0-9]{12}-[a-z0-9-]+$ ]] \
    || e2e_die "refusing to touch an unexpected name prefix: ${prefix}"
}

e2e_assert_glue_prefix() {
  local prefix="$1"
  [[ "$prefix" =~ ^aoelvp94_dbt_athena_test_[0-9]{12}_[a-z0-9_]+$ ]] \
    || e2e_die "refusing to touch an unexpected Glue prefix: ${prefix}"
}

e2e_project_tag() {
  printf '%s\n' "dbt-v2-athena-e2e"
}

# Print the AWS and Terraform operations a real up would perform.
e2e_print_up_plan() {
  local region="$1"
  cat <<EOF
dry-run: no AWS API calls. A real ./infra/up.sh would run:

  aws sts get-caller-identity
  terraform -chdir=infra/terraform init -input=false
  terraform -chdir=infra/terraform apply -input=false -auto-approve

Terraform would create, tagged project=$(e2e_project_tag), named
aoelvp94-dbt-athena-test-<account-id>-${region} (Glue databases use underscores):

  s3:CreateBucket
  s3:PutPublicAccessBlock          (all four blocks true)
  s3:PutBucketOwnershipControls    (BucketOwnerEnforced)
  s3:PutBucketVersioning           (Enabled)
  s3:PutBucketEncryption           (AES256)
  s3:PutBucketLifecycleConfiguration
      expire current objects after 1 day
      expire noncurrent versions after 1 day
      abort incomplete multipart uploads after 1 day
  s3:PutBucketTagging
  athena:CreateWorkGroup
      force_destroy, enforce_workgroup_configuration
      BytesScannedCutoffPerQuery=1073741824
      result location s3://<bucket>/athena-results/
  glue:CreateDatabase              (<glue-prefix>_analytics)
  glue:CreateDatabase              (<glue-prefix>_scratch)

Then write:
  infra/.state/outputs.json
  infra/.state/e2e.env
  infra/.state/profiles.yml

Pass --plan to run 'terraform plan' (read-only AWS calls) instead of this printout.
EOF
}

e2e_print_down_plan() {
  local region="$1"
  cat <<EOF
dry-run: no AWS API calls. A real ./infra/down.sh would run, for
aoelvp94-dbt-athena-test-<account-id>-${region}:

  aws sts get-caller-identity
  aws glue get-databases
  aws glue get-tables --database-name <each matching database>
  aws glue delete-table --database-name <db> --name <table>     # dbt-created tables
  terraform -chdir=infra/terraform destroy -input=false -auto-approve
  aws s3api list-object-versions --bucket <bucket>              # if the bucket remains
  aws s3api delete-objects                                      # current and noncurrent versions
  aws s3api abort-multipart-upload                              # leftover uploads
  aws s3api delete-bucket --bucket <bucket>
  aws athena delete-work-group --work-group <name> --recursive-delete
  aws glue delete-database --name <db>
  rm -f infra/.state/e2e.env infra/.state/profiles.yml infra/.state/outputs.json

Then verify, and exit non-zero if any of these still match the prefix or the
project=$(e2e_project_tag) tag:

  aws s3api list-buckets
  aws athena list-work-groups
  aws glue get-databases
  aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=$(e2e_project_tag)

Pass --plan to run 'terraform plan -destroy' (read-only AWS calls).
EOF
}

e2e_tf() {
  e2e_need_cmd terraform
  terraform -chdir="$(e2e_tf_dir)" "$@"
}

e2e_terraform_init() {
  e2e_tf init -input=false -no-color
}

e2e_load_outputs_if_present() {
  local out="${1:-$(e2e_state_dir)/outputs.json}"
  [[ -f "$out" ]] || return 1
  return 0
}
