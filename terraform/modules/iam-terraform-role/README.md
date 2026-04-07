# Module: iam-terraform-role

## Overview

Provisions a least-privilege IAM role for running Terraform in a given environment. The module creates:

- **IAM Role** (`terraform-{environment}`) — the role Terraform assumes to provision infrastructure. Trusted by any IAM principal in the account, access is controlled by the group policy below.
- **IAM Group** (`terraform-{environment}`) — IAM users added to this group are granted `sts:AssumeRole` on the terraform role. Users outside the group cannot assume the role.
- **IAM Managed Policy Attachments** — attaches a caller-supplied list of AWS managed policies to the terraform role (e.g. `AmazonDynamoDBFullAccess_v2`, `AmazonEKSClusterPolicy`).
- **IAM Inline Policy** — scoped IAM management permissions allowing the terraform role to create and manage IRSA roles for Kubernetes pods, with privilege escalation prevention controls.
- **Permissions Boundary Policy** — a standalone IAM policy that caps the maximum permissions any role created by terraform can ever exercise. Automatically attached to all roles terraform provisions.

## Privilege Escalation Prevention

The module implements multiple controls to prevent privilege escalation:

1. **Permissions boundary required on role creation** — `iam:CreateRole` is only permitted if the boundary policy is attached in the same API call. Terraform cannot create unbounded roles.
2. **Policy attachment scoped to project prefix** — `iam:AttachRolePolicy` is restricted to policies matching `{project_scope_limit_prefix}-*`, preventing attachment of broad AWS managed policies to project roles.
3. **Boundary deletion denied** — `iam:DeleteRolePermissionsBoundary` is explicitly denied, preventing removal of the boundary from managed roles.
4. **Boundary modification denied** — `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, and `iam:SetDefaultPolicyVersion` are denied on the boundary policy ARN, preventing the boundary document from being weakened.

## Assumptions

- **Single AWS account per environment** — IAM resource scoping is limited to project prefix (`{project_scope_limit_prefix}-*`). Environment-level isolation (dev vs staging vs prod) is assumed to be handled via separate AWS accounts. Using this module in a shared account means the terraform role could theoretically manage same-prefix resources across environments.
- **Bootstrap context** — this module is intended to be called from a bootstrap Terraform root provisioned with admin credentials. The terraform role it creates should be used for all subsequent infrastructure provisioning.
- **IRSA role naming convention** — roles created by the terraform role must follow the `{project_scope_limit_prefix}-*` naming convention for IAM policy conditions to apply correctly.
- **IAM read access** — callers are expected to attach `IAMReadOnlyAccess` via `terraform_role_allowed_managed_policies` so Terraform can read IAM state during plan/apply.

## Usage

```hcl
module "terraform_role" {
  source = "../../modules/iam-terraform-role"

  account_id  = var.account_id
  environment = "dev"
  region      = "us-east-2"

  project_scope_limit_prefix = "iss-tracker"

  terraform_role_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccessV2",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  ]

  permission_boundary_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
  ]

  tags = {
    environment = "dev"
    project     = "iss-tracker"
  }
}
```

## Inputs

| Name | Description | Type | Required |
|------|-------------|------|----------|
| `account_id` | AWS Account ID. Used to construct IAM ARNs and the role trust policy. Marked sensitive. | `string` | yes |
| `environment` | Environment name (e.g. `dev`, `staging`, `prod`). Used in resource names. | `string` | yes |
| `region` | AWS region. Used to scope resource ARNs in IAM policies. | `string` | yes |
| `project_scope_limit_prefix` | Project name prefix used to scope IAM resource constraints (e.g. `iss-tracker`). | `string` | yes |
| `terraform_role_allowed_managed_policies` | List of AWS managed policy ARNs to attach to the terraform role. | `list` | no |
| `permission_boundary_allowed_managed_policies` | List of AWS managed policy ARNs that the terraform role is permitted to attach to IRSA roles it creates. | `list` | no |
| `tags` | Tags to attach to provisioned resources. | `map` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `role_name` | Name of the terraform IAM role | no |
| `role_arn` | ARN of the terraform IAM role | yes |
| `group_name` | Name of the IAM group permitted to assume the terraform role | no |
| `permission_boundary_arn` | ARN of the permissions boundary policy | yes |

..