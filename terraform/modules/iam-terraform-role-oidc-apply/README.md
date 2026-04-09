# Module: iam-terraform-role-oidc-apply

Provisions an IAM role for CI pipelines running `terraform apply` via GitHub Actions OIDC federation. A permissions boundary is always attached, capping the maximum permissions the role can exercise regardless of which managed or inline policies are attached.

All policy content is caller-supplied. The module handles structure only: role creation with OIDC trust policy, boundary attachment, managed policy attachments, and optional inline policy.

## Usage

```hcl
module "terraform_role_github_apply" {
  source = "../../modules/iam-terraform-role-oidc-apply"

  role_name               = "terraform-dev-github"
  oidc_provider_arn       = aws_iam_openid_connect_provider.github_actions.arn
  oidc_subjects = [
    "repo:my-org/my-repo:ref:refs/heads/develop",
    "repo:my-org/my-repo:ref:refs/heads/main",
  ]
  permission_boundary_arn = module.boundary.boundary_arn

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess",
  ]

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoleManagementWithBoundary"
        Effect = "Allow"
        Action = ["iam:CreateRole", "iam:DeleteRole"]
        Resource = "arn:aws:iam::123456789012:role/iss-tracker-*"
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = "arn:aws:iam::123456789012:policy/iss-tracker-dev-boundary"
          }
        }
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
| `permission_boundary_arn` | ARN of the permission boundary to attach to the role | `string` | — | yes |
| `managed_policy_arns` | AWS managed policy ARNs to attach | `list(string)` | `[]` | no |
| `inline_policy_json` | JSON inline policy document. Constructed with `jsonencode()` by the caller. | `string` | `null` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `role_name` | Name of the IAM role | no |
| `role_arn` | ARN of the IAM role | yes |