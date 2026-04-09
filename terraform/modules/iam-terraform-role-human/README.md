# Module: iam-terraform-role-human

Provisions an IAM role for human operators running Terraform. Trust is via IAM group — users added to the group are granted `sts:AssumeRole`. A permissions boundary is always attached, capping the maximum permissions the role can exercise.

All policy content (managed policies, inline policy) is caller-supplied. The module handles structure only: role creation, boundary attachment, group wiring.

## Usage

```hcl
module "terraform_role_human" {
  source = "../../modules/iam-terraform-role-human"

  role_name               = "terraform-dev-human"
  account_id              = sensitive(data.aws_caller_identity.current.account_id)
  permission_boundary_arn = module.boundary.boundary_arn

  managed_policy_arns = [
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
| `account_id` | AWS account ID for trust policy construction. Marked sensitive. | `string` | — | yes |
| `permission_boundary_arn` | ARN of the permission boundary to attach to the role | `string` | — | yes |
| `managed_policy_arns` | AWS managed policy ARNs to attach | `list(string)` | `[]` | no |
| `inline_policy_json` | JSON inline policy document. Constructed with `jsonencode()` by the caller. | `string` | `null` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `role_name` | Name of the IAM role | no |
| `role_arn` | ARN of the IAM role | yes |
| `group_name` | Name of the IAM group whose members may assume the role | no |