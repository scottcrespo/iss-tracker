# Module: iam-permission-boundary

Creates a standalone IAM managed policy intended for use as a permissions boundary. The policy document is fully caller-supplied — this module only handles resource creation and outputs the ARN for use by role modules.

## Usage

```hcl
module "boundary" {
  source = "../../modules/iam-permission-boundary"

  name = "iss-tracker-dev-boundary"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowDynamoDB"
        Effect   = "Allow"
        Action   = "dynamodb:*"
        Resource = "arn:aws:dynamodb:us-east-2:123456789012:table/iss-tracker-*"
      },
      {
        Sid      = "DenyIAM"
        Effect   = "Deny"
        Action   = "iam:*"
        Resource = "*"
      }
    ]
  })

  tags = { environment = "dev" }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `name` | Name of the boundary policy | `string` | — | yes |
| `policy_json` | JSON policy document for the boundary | `string` | — | yes |
| `tags` | Tags to apply to the policy | `map(string)` | `{}` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `boundary_arn` | ARN of the boundary policy | yes |
| `boundary_name` | Name of the boundary policy | no |