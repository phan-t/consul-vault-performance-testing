# Perf assets (k6 scripts, vault-benchmark configs, dashboards) and results.

resource "aws_s3_bucket" "perf" {
  bucket        = "${var.name}-perf-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "perf" {
  bucket                  = aws_s3_bucket.perf.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "perf" {
  bucket = aws_s3_bucket.perf.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

locals {
  perf_dir   = "${path.module}/../perf"
  perf_files = [for f in fileset(local.perf_dir, "**") : f if !startswith(f, "results/") && !strcontains(f, "__pycache__")]
}

resource "aws_s3_object" "perf" {
  for_each = toset(local.perf_files)

  bucket = aws_s3_bucket.perf.id
  key    = "assets/perf/${each.value}"
  source = "${local.perf_dir}/${each.value}"
  etag   = filemd5("${local.perf_dir}/${each.value}")
}

resource "aws_s3_object" "dashboard" {
  bucket = aws_s3_bucket.perf.id
  key    = "assets/monitoring/consul-vault-perf.json"
  source = "${path.module}/files/consul-vault-perf.json"
  etag   = filemd5("${path.module}/files/consul-vault-perf.json")
}
