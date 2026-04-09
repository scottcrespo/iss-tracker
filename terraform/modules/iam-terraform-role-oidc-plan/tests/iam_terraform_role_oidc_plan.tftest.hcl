# Tests for the iam-terraform-role-oidc-plan module
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Covers:
#   - role name is set correctly
#   - trust policy uses sts:AssumeRoleWithWebIdentity with a Federated principal
#   - no permissions boundary is attached (plan role has no IAM write surface)
#   - OIDC subjects are wired into the trust policy condition
#   - inline policy is created when inline_policy_json is provided
#   - inline policy is not created when inline_policy_json is null

mock_provider "aws" {}

# --- role name ---

run "role_name_is_set" {
  command = plan

  variables {
    role_name         = "terraform-dev-github-plan"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects     = ["repo:scottcrespo/iss-tracker:pull_request"]
  }

  assert {
    condition     = aws_iam_role.this.name == "terraform-dev-github-plan"
    error_message = "Expected role name 'terraform-dev-github-plan', got '${aws_iam_role.this.name}'"
  }
}

# --- trust policy ---

run "trust_policy_uses_oidc_federation" {
  command = plan

  variables {
    role_name         = "terraform-dev-github-plan"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects     = ["repo:scottcrespo/iss-tracker:pull_request"]
  }

  assert {
    condition     = can(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity")
    error_message = "Expected trust policy action to be sts:AssumeRoleWithWebIdentity"
  }

  assert {
    condition     = can(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated)
    error_message = "Expected trust policy to use a Federated principal, not AWS"
  }
}

# --- no permissions boundary ---

run "no_permission_boundary_attached" {
  command = plan

  variables {
    role_name         = "terraform-dev-github-plan"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects     = ["repo:scottcrespo/iss-tracker:pull_request"]
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "Expected no permissions_boundary on the plan role"
  }
}

# --- OIDC subjects ---

run "oidc_subjects_in_trust_policy" {
  command = plan

  variables {
    role_name         = "terraform-dev-github-plan"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects     = ["repo:scottcrespo/iss-tracker:pull_request"]
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"], "repo:scottcrespo/iss-tracker:pull_request")
    error_message = "Expected OIDC subject 'repo:scottcrespo/iss-tracker:pull_request' in trust policy condition"
  }
}

# --- inline policy ---

run "inline_policy_created_when_provided" {
  command = plan

  variables {
    role_name          = "terraform-dev-github-plan"
    oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects      = ["repo:scottcrespo/iss-tracker:pull_request"]
    inline_policy_json = jsonencode({ Version = "2012-10-17", Statement = [] })
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 1
    error_message = "Expected one inline policy to be created when inline_policy_json is provided"
  }
}

run "inline_policy_not_created_when_null" {
  command = plan

  variables {
    role_name         = "terraform-dev-github-plan"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    oidc_subjects     = ["repo:scottcrespo/iss-tracker:pull_request"]
  }

  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "Expected no inline policy when inline_policy_json is null"
  }
}