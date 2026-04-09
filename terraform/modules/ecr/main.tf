resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = var.encryption_type
    kms_key         = var.encryption_type == "KMS" ? var.kms_key_arn : null
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        # Remove untagged images quickly to avoid accumulating stale layers
        rulePriority = 1
        description  = "Remove untagged images after ${var.untagged_image_retention_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        # Cap total tagged images to control storage costs
        rulePriority = 2
        description  = "Keep only the last ${var.max_tagged_images} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_tagged_images
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}