# SPDX-License-Identifier: Apache-2.0

output "account_id" {
  description = "AWS account that owns the resources."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "Region the stack was applied in."
  value       = var.region
}

output "project_tag" {
  description = "Tag key/value project=<this> on every resource."
  value       = var.project_tag
}

output "name_prefix" {
  description = "Bucket and Athena workgroup name."
  value       = local.name_prefix
}

output "glue_prefix" {
  description = "Prefix of the Glue database names."
  value       = local.glue_prefix
}

output "bucket_name" {
  description = "S3 bucket for query results and table data."
  value       = aws_s3_bucket.results.bucket
}

output "s3_staging_dir" {
  description = "Profile s3_staging_dir. Matches the enforced workgroup result location."
  value       = "s3://${aws_s3_bucket.results.bucket}/${local.results_prefix}"
}

output "s3_data_dir" {
  description = "Profile s3_data_dir. Iceberg table locations are created under this prefix."
  value       = "s3://${aws_s3_bucket.results.bucket}/${local.data_prefix}"
}

output "work_group" {
  description = "Athena workgroup name."
  value       = aws_athena_workgroup.e2e.name
}

output "analytics_database" {
  description = "Glue database used as the dbt target schema."
  value       = aws_glue_catalog_database.analytics.name
}

output "scratch_database" {
  description = "Second Glue database created by this stack."
  value       = aws_glue_catalog_database.scratch.name
}

output "bytes_scanned_cutoff_per_query" {
  description = "Per-query scan cap configured on the workgroup."
  value       = var.bytes_scanned_cutoff_per_query
}
