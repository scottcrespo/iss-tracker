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

data "aws_caller_identity" "current" {}

# Look up the GitHub Actions OIDC provider provisioned during initial bootstrap.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github_actions.arn

  # Plan role may be assumed from any pull request targeting any branch.
  # Using pull_request subject intentionally — this role carries read-only permissions
  # so broad PR access is acceptable.
  oidc_subjects = [
    "repo:scottcrespo/iss-tracker:pull_request",
  ]

  # Scoped inline policy — grants access to the S3 tfstate bucket only.
  plan_inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTFStateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::iss-tracker-tfstate-dev",
          "arn:aws:s3:::iss-tracker-tfstate-dev/*",
        ]
      },
    ]
  })
}

module "terraform_role_plan" {
  source = "../../../../../modules/iam-terraform-role-oidc-plan"

  role_name         = "terraform-dev-github-plan"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_subjects     = local.oidc_subjects

  inline_policy_json = local.plan_inline_policy_json

  tags = { environment = "dev" }
}