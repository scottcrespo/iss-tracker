# Tests for the ecr module
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Covers:
#   - repository_name is set correctly on the resource
#   - encryption_type defaults to AES256
#   - encryption_type = KMS wires in the kms_key_arn
#   - invalid encryption_type fails validation
#   - untagged_image_retention_days is reflected in the lifecycle policy
#   - max_tagged_images is reflected in the lifecycle policy
#   - scan_on_push is always enabled regardless of inputs

mock_provider "aws" {}

# --- repository_name ---

run "repository_name_is_set" {
  command = plan

  variables {
    repository_name = "iss-api"
  }

  assert {
    condition     = aws_ecr_repository.this.name == "iss-api"
    error_message = "Expected repository name 'iss-api', got '${aws_ecr_repository.this.name}'"
  }
}

# --- encryption_type ---

run "encryption_defaults_to_aes256" {
  command = apply

  variables {
    repository_name = "iss-api"
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "Expected default encryption_type to be AES256"
  }
}

run "encryption_kms_sets_key_arn" {
  command = plan

  variables {
    repository_name = "iss-api"
    encryption_type = "KMS"
    kms_key_arn     = "arn:aws:kms:us-east-2:123456789012:key/mrk-abc123"
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "KMS"
    error_message = "Expected encryption_type to be KMS"
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].kms_key == "arn:aws:kms:us-east-2:123456789012:key/mrk-abc123"
    error_message = "Expected kms_key to be set when encryption_type is KMS"
  }
}

run "invalid_encryption_type_fails_validation" {
  command = plan

  variables {
    repository_name = "iss-api"
    encryption_type = "INVALID"
  }

  expect_failures = [
    var.encryption_type
  ]
}

# --- untagged_image_retention_days ---

run "untagged_retention_default_is_7_days" {
  command = plan

  variables {
    repository_name = "iss-api"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 7
    error_message = "Expected default untagged retention to be 7 days"
  }
}

run "untagged_retention_custom_value" {
  command = plan

  variables {
    repository_name               = "iss-api"
    untagged_image_retention_days = 3
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 3
    error_message = "Expected untagged retention to be 3 days"
  }
}

# --- max_tagged_images ---

run "max_tagged_images_default_is_20" {
  command = plan

  variables {
    repository_name = "iss-api"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 20
    error_message = "Expected default max_tagged_images to be 20"
  }
}

run "max_tagged_images_custom_value" {
  command = plan

  variables {
    repository_name   = "iss-api"
    max_tagged_images = 10
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 10
    error_message = "Expected max_tagged_images to be 10"
  }
}

# --- scan_on_push ---

run "scan_on_push_always_enabled" {
  command = plan

  variables {
    repository_name = "iss-api"
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push == true
    error_message = "Expected scan_on_push to always be true"
  }
}