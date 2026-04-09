# Tests for the iam-terraform-role-human module
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Covers:
#   - role name is set correctly
#   - trust policy uses sts:AssumeRole with an AWS principal
#   - permissions boundary is attached to the role
#   - IAM group is created
#   - inline policy is created when inline_policy_json is provided
#   - inline policy is not created when inline_policy_json is null

mock_provider "aws" {}

# --- role name ---

run "role_name_is_set" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
  }

  assert {
    condition     = aws_iam_role.this.name == "terraform-dev-human"
    error_message = "Expected role name 'terraform-dev-human', got '${aws_iam_role.this.name}'"
  }
}

# --- trust policy ---

run "trust_policy_uses_iam_principal" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
  }

  assert {
    condition     = can(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRole")
    error_message = "Expected trust policy action to be sts:AssumeRole"
  }

  assert {
    condition     = can(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.AWS)
    error_message = "Expected trust policy to use an AWS principal, not Federated"
  }
}

# --- permissions boundary ---

run "permission_boundary_is_attached" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
    error_message = "Expected permissions_boundary to be attached to the role"
  }
}

# --- IAM group ---

run "iam_group_is_created" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
  }

  assert {
    condition     = aws_iam_group.this.name == "terraform-dev-human-users"
    error_message = "Expected IAM group 'terraform-dev-human-users' to be created"
  }
}

# --- inline policy ---

run "inline_policy_created_when_provided" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
    inline_policy_json      = jsonencode({ Version = "2012-10-17", Statement = [] })
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 1
    error_message = "Expected one inline policy to be created when inline_policy_json is provided"
  }
}

run "inline_policy_not_created_when_null" {
  command = plan

  variables {
    role_name               = "terraform-dev-human"
    account_id              = "123456789012"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "Expected no inline policy when inline_policy_json is null"
  }
}
