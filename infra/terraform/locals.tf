# SPDX-License-Identifier: Apache-2.0
#
# Naming formula, duplicated in infra/lib.sh. infra/up.sh compares Terraform's
# name_prefix output with the shell formula and stops if they drift.

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.name_prefix_base}-${data.aws_caller_identity.current.account_id}-${var.region}"
  glue_prefix = "${var.glue_prefix_base}_${data.aws_caller_identity.current.account_id}_${replace(var.region, "-", "_")}"

  analytics_database = "${local.glue_prefix}_analytics"
  scratch_database   = "${local.glue_prefix}_scratch"

  results_prefix = "athena-results/"
  data_prefix    = "data/"
}
