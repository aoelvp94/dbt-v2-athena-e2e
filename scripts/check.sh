#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Offline checks: shellcheck, Terraform fmt/validate, cost math, dry-run.
# Does not contact AWS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}

need shellcheck
need terraform
need jq
need bash

echo "shellcheck"
shellcheck -x -P "${ROOT}/infra" -P "${ROOT}/scripts" \
  "${ROOT}/infra/lib.sh" \
  "${ROOT}/infra/aws_ops.sh" \
  "${ROOT}/infra/up.sh" \
  "${ROOT}/infra/down.sh" \
  "${ROOT}/infra/status.sh" \
  "${ROOT}/scripts/build_dbt.sh" \
  "${ROOT}/scripts/run_e2e.sh" \
  "${ROOT}/scripts/cost.sh" \
  "${ROOT}/scripts/check.sh"

echo "jq iam policy"
jq -e . "${ROOT}/infra/iam-least-privilege.json" >/dev/null

echo "cost self-test"
"${ROOT}/scripts/cost.sh" --self-test

echo "terraform fmt"
terraform -chdir="${ROOT}/infra/terraform" fmt -check -recursive -diff

echo "up/down dry-run"
"${ROOT}/infra/up.sh" --dry-run --region us-east-1 >/dev/null
"${ROOT}/infra/down.sh" --dry-run --region us-west-2 >/dev/null

echo "offline checks passed"
