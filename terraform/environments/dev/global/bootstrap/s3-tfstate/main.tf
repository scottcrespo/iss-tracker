provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = {
      terraform_managed = "true"
      project           = "iss-tracker"
      environment       = "dev"
    }
  }
}

resource "aws_s3_bucket" "terraform_state" {
  # Bucket name is hardcoded because the Terraform backend block does not support
  # variable interpolation — it is evaluated before variables are loaded. The name
  # must match the bucket value in any backend configs that reference this state bucket.
  # This is a known Terraform limitation and the bucket name is not considered sensitive.
  bucket = "iss-tracker-tfstate-dev"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "S3 Remote State"
    Environment = "dev"
  }
}

resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}