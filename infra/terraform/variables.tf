# SPDX-License-Identifier: Apache-2.0

variable "region" {
  description = "AWS region for the workgroup, Glue databases, and bucket name. Default us-east-1."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z0-9-]+-[0-9]+$", var.region))
    error_message = "region must look like us-east-1."
  }
}

variable "project_tag" {
  description = "Tag applied to every resource. down.sh verification looks for this tag."
  type        = string
  default     = "dbt-v2-athena-e2e"
}

variable "name_prefix_base" {
  description = "Stable prefix for the bucket and Athena workgroup. Account id and region are appended."
  type        = string
  default     = "aoelvp94-dbt-athena-test"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,40}$", var.name_prefix_base))
    error_message = "name_prefix_base must be a lowercase S3-safe prefix."
  }
}

variable "glue_prefix_base" {
  description = "Stable prefix for Glue database names. Hyphens are not legal in Glue database names."
  type        = string
  default     = "aoelvp94_dbt_athena_test"

  validation {
    condition     = can(regex("^[a-z0-9_]+$", var.glue_prefix_base))
    error_message = "glue_prefix_base must be lowercase letters, digits, and underscores."
  }
}

variable "bytes_scanned_cutoff_per_query" {
  description = "Athena workgroup BytesScannedCutoffPerQuery. 1 GiB keeps a runaway query from scanning a large table."
  type        = number
  default     = 1073741824

  validation {
    condition     = var.bytes_scanned_cutoff_per_query >= 10485760
    error_message = "Athena rejects a bytes scanned cutoff below 10 MiB."
  }
}
