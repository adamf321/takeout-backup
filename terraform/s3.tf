resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name

  tags = {
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "transition-to-glacier-deep-archive"
    status = "Enabled"

    filter {
      prefix = "takeout/"
    }

    transition {
      days          = var.glacier_transition_days
      storage_class = "DEEP_ARCHIVE"
    }

    # Clean up old versions once a newer one has aged past the same window,
    # so accidental overwrite-protection from versioning doesn't quietly
    # accumulate storage cost forever.
    noncurrent_version_transition {
      noncurrent_days = var.glacier_transition_days
      storage_class   = "DEEP_ARCHIVE"
    }

    dynamic "expiration" {
      for_each = var.backup_retention_years > 0 ? [1] : []
      content {
        days = var.backup_retention_years * 365
      }
    }

    dynamic "noncurrent_version_expiration" {
      for_each = var.backup_retention_years > 0 ? [1] : []
      content {
        noncurrent_days = var.backup_retention_years * 365
      }
    }
  }

  # Abort incomplete multipart uploads (e.g. from an interrupted rclone
  # transfer) after 7 days so they don't sit around costing money silently.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}
