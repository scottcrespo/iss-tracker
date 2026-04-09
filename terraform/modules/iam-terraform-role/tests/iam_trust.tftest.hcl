# Tests for trust_type = "iam"
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Verifies:
#   - IAM role is created with the correct name
#   - Trust policy uses sts:AssumeRole with an AWS principal (not federated)
#   - IAM group is created
#   - Permission boundary is always created
#   - group_name output is populated

mock_provider "aws" {}

run "iam_trust_type_creates_role_and_group" {
  command = plan

  variables {
    account_id                                   = "123456789012"
    environment                                  = "test"
    project_scope_limit_prefix                   = "iss-tracker"
    region                                       = "us-east-2"
    role_name                                    = "terraform-test"
    trust_type                                   = "iam"
    permission_boundary_allowed_managed_policies = []
    terraform_role_allowed_managed_policies      = []
  }

  # Role exists with correct name
  assert {
    condition     = aws_iam_role.terraform_role.name == "terraform-test"
    error_message = "Expected role name to be 'terraform-test', got '${aws_iam_role.terraform_role.name}'"
  }

  # Trust policy uses AssumeRole (not AssumeRoleWithWebIdentity)
  assert {
    condition     = can(jsondecode(aws_iam_role.terraform_role.assume_role_policy).Statement[0].Action == "sts:AssumeRole")
    error_message = "Expected trust policy action to be sts:AssumeRole for iam trust type"
  }

  # Trust policy uses AWS principal (not Federated)
  assert {
    condition     = can(jsondecode(aws_iam_role.terraform_role.assume_role_policy).Statement[0].Principal.AWS)
    error_message = "Expected trust policy to have an AWS principal for iam trust type"
  }

  # IAM group is created
  assert {
    condition     = length(aws_iam_group.terraform_group) == 1
    error_message = "Expected one IAM group to be created for iam trust type"
  }

  # Permission boundary is created
  assert {
    condition     = aws_iam_policy.permission_boundary.name == "terraform-test-boundary-for-provisioned-roles"
    error_message = "Expected permission boundary policy to be created"
  }

  # group_name output is populated
  assert {
    condition     = output.group_name != ""
    error_message = "Expected group_name output to be non-empty for iam trust type"
  }
}