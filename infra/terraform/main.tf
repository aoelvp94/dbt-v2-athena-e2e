# SPDX-License-Identifier: Apache-2.0
#
# Throwaway Athena sandbox for the dbt v2 end-to-end harness.
# One bucket, one workgroup, two Glue databases. No NAT, no KMS, no CloudTrail.

resource "aws_s3_bucket" "results" {
  bucket        = local.name_prefix
  force_destroy = true

  tags = {
    Name = local.name_prefix
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  depends_on = [aws_s3_bucket_versioning.results]

  rule {
    id     = "expire-objects-after-1-day"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_athena_workgroup" "e2e" {
  name          = local.name_prefix
  description   = "Throwaway workgroup for the dbt v2 Athena end-to-end harness."
  state         = "ENABLED"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_per_query

    result_configuration {
      output_location = "s3://${aws_s3_bucket.results.bucket}/${local.results_prefix}"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = {
    Name = local.name_prefix
  }
}

resource "aws_glue_catalog_database" "analytics" {
  name         = local.analytics_database
  description  = "dbt target schema for the dbt v2 Athena end-to-end harness."
  location_uri = "s3://${aws_s3_bucket.results.bucket}/${local.data_prefix}${local.analytics_database}/"

  tags = {
    Name = local.analytics_database
  }
}

resource "aws_glue_catalog_database" "scratch" {
  name         = local.scratch_database
  description  = "Second Glue database so cleanup and catalog listing cover more than one schema. dbt does not write here unless a model is pointed at it."
  location_uri = "s3://${aws_s3_bucket.results.bucket}/${local.data_prefix}${local.scratch_database}/"

  tags = {
    Name = local.scratch_database
  }
}
