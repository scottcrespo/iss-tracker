# Module: iam-terraform-role-oidc-plan

Provisions a read-only IAM role for CI pipelines running `terraform plan` via GitHub Actions OIDC federation. No permissions boundary is attached — this role intentionally has no `iam:Create*` permissions so there is no privilege escalation surface to constrain.

All policy content is caller-supplied. The module handles structure only: role creation with OIDC trust policy, managed policy attachments, and optional inline policy.

## Usage

```hcl
module "terraform_role_github_plan" {
  source = "../../modules/iam-terraform-role-oidc-plan"

  role_name         = "terraform-dev-github-plan"
  oidc_provider_arn = aws_iam_openid_connect_provider.github_actions.arn
  oidc_subjects     = ["repo:my-org/my-repo:pull_request"]

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]

  # Optional: scoped inline policy for S3 state bucket access
  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTFStateBucketAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::my-tfstate-bucket",
          "arn:aws:s3:::my-tfstate-bucket/*",
        ]
      }
    ]
  })

  tags = { environment = "dev" }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `role_name` | Name of the IAM role | `string` | — | yes |
| `oidc_provider_arn` | ARN of the IAM OIDC identity provider | `string` | — | yes |
| `oidc_subjects` | OIDC subject claim values permitted to assume this role | `list(string)` | — | yes |
| `managed_policy_arns` | AWS managed policy ARNs to attach | `list(string)` | `[]` | no |
| `inline_policy_json` | JSON inline policy document. Constructed with `jsonencode()` by the caller. | `string` | `null` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `role_name` | Name of the IAM role | no |
| `role_arn` | ARN of the IAM role | yes |