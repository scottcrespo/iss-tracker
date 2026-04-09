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

# GitHub Actions OIDC provider — shared by all CI roles that use OIDC federation.
# Provision this root before iam-terraform-role-oidc-plan or iam-terraform-role-oidc-apply.
#
# AWS validates the provider thumbprint automatically for github.com endpoints,
# but Terraform requires at least one value in the list. The thumbprints below
# correspond to GitHub's two OIDC root CAs and should remain stable.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
  sensitive   = true
}