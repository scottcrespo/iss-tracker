# Tests for trust_type = "oidc"
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Verifies:
#   - IAM role is created with the correct name
#   - Trust policy uses sts:AssumeRoleWithWebIdentity with a Federated principal
#   - No IAM group is created
#   - Permission boundary is always created
#   - group_name output is empty string

mock_provider "aws" {}

run "oidc_trust_type_creates_role_without_group" {
  command = plan

  variables {
    account_id                                   = "123456789012"
    environment                                  = "test"
    project_scope_limit_prefix                   = "iss-tracker"
    region                                       = "us-east-2"
    role_name                                    = "terraform-test-ci"
    trust_type                                   = "oidc"
    oidc_provider_arn                            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects                                = ["repo:scottcrespo/iss-tracker:ref:refs/heads/develop"]
    permission_boundary_allowed_managed_policies = []
    terraform_role_allowed_managed_policies      = []
  }

  # Role exists with correct name
  assert {
    condition     = aws_iam_role.terraform_role.name == "terraform-test-ci"
    error_message = "Expected role name to be 'terraform-test-ci', got '${aws_iam_role.terraform_role.name}'"
  }

  # Trust policy uses AssumeRoleWithWebIdentity (not AssumeRole)
  assert {
    condition     = can(jsondecode(aws_iam_role.terraform_role.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity")
    error_message = "Expected trust policy action to be sts:AssumeRoleWithWebIdentity for oidc trust type"
  }

  # Trust policy uses Federated principal (not AWS)
  assert {
    condition     = can(jsondecode(aws_iam_role.terraform_role.assume_role_policy).Statement[0].Principal.Federated)
    error_message = "Expected trust policy to have a Federated principal for oidc trust type"
  }

  # No IAM group is created
  assert {
    condition     = length(aws_iam_group.terraform_group) == 0
    error_message = "Expected no IAM group to be created for oidc trust type"
  }

  # Permission boundary is still created
  assert {
    condition     = aws_iam_policy.permission_boundary.name == "terraform-test-ci-boundary-for-provisioned-roles"
    error_message = "Expected permission boundary policy to be created regardless of trust type"
  }

  # group_name output is empty
  assert {
    condition     = output.group_name == ""
    error_message = "Expected group_name output to be empty string for oidc trust type"
  }
}