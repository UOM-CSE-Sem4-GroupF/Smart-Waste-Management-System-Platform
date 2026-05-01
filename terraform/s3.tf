# Group F - Smart Waste Management System
# S3 Bucket - Shared Artifact Storage
# Owner: F4 Platform Team
#
# Used by:
#   F2 - Airflow DAGs, MLflow model artifacts, Spark checkpoints
#   F4 - Terraform state (optional, see backend.tf)
#
# NOTE: force_destroy = false intentionally prevents terraform destroy from
# wiping ML model artifacts and DAGs. Empty the bucket manually before destroy:
#   aws s3 rm s3://<bucket-name> --recursive

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "swms_artifacts" {
  bucket        = "swms-artifacts-${random_id.bucket_suffix.hex}"
  force_destroy = false

  tags = {
    Name    = "swms-artifacts"
    Purpose = "Artifact Storage"
  }
}

resource "aws_s3_bucket_public_access_block" "swms_artifacts" {
  bucket = aws_s3_bucket.swms_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "swms_artifacts" {
  bucket = aws_s3_bucket.swms_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "swms_artifacts" {
  bucket = aws_s3_bucket.swms_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Allow EKS node role to read/write artifacts.
# F2 services (Airflow, Spark, MLflow) run on the worker nodes and need access.
resource "aws_s3_bucket_policy" "swms_artifacts" {
  bucket = aws_s3_bucket.swms_artifacts.id

  # public_access_block must be applied first to avoid a race condition
  depends_on = [aws_s3_bucket_public_access_block.swms_artifacts]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEKSNodeAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.eks_nodes.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.swms_artifacts.arn,
          "${aws_s3_bucket.swms_artifacts.arn}/*",
        ]
      }
    ]
  })
}
