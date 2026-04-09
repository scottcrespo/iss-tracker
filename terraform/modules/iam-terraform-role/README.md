# Module: iam-terraform-role

## Overview

Provisions a least-privilege IAM role for running Terraform in a given environment. The module creates:

- **IAM Role** — the role Terraform assumes to provision infrastructure. Trust policy is controlled by `trust_type` (IAM group or GitHub Actions OIDC).
- **IAM Group** (`terraform-{role_name}`) — created when `trust_type = "iam"`. IAM users added to this group are granted `sts:AssumeRole` on the terraform role.
- **IAM Managed Policy Attachments** — attaches a caller-supplied list of AWS managed policies to the terraform role.
- **IAM Inline Policy** — scoped IAM management permissions with privilege escalation prevention controls. Only created when `role_type = "full"`.
- **Permissions Boundary Policy** — a standalone IAM policy that caps the maximum permissions any role created by terraform can ever exercise. Always created regardless of `role_type`.

## Role Types

The `role_type` variable controls whether the inline IAM write policy is attached:

| `role_type` | Inline policy | Intended use |
|-------------|---------------|--------------|
| `full` (default) | Created | Human operators and CI apply jobs that need to create/modify infrastructure |
| `plan` | Not created | CI plan jobs on pull requests — read-only, no ability to modify infrastructure |

Using `role_type = "plan"` with `ReadOnlyAccess` as the managed policy ensures that untrusted branches (feature branches opening PRs) can only read state and produce a plan — they cannot make any changes even if the workflow were compromised.

## Trust Types

The `trust_type` variable controls who can assume the role:

| `trust_type` | Principal | IAM group created |
|-------------|-----------|-------------------|
| `iam` (default) | AWS account root, access via IAM group | Yes |
| `oidc` | GitHub Actions via OIDC federation | No |

## Privilege Escalation Prevention

The module implements multiple controls to prevent privilege escalation (applies to `role_type = "full"` only):

1. **Permissions boundary required on role creation** — `iam:CreateRole` is only permitted if the boundary policy is attached in the same API call. Terraform cannot create unbounded roles.
2. **Policy attachment scoped to project prefix** — `iam:AttachRolePolicy` is restricted to policies matching `{project_scope_limit_prefix}-*`, preventing attachment of broad AWS managed policies to project roles.
3. **Boundary deletion denied** — `iam:DeleteRolePermissionsBoundary` is explicitly denied, preventing removal of the boundary from managed roles.
4. **Boundary modification denied** — `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, and `iam:SetDefaultPolicyVersion` are denied on the boundary policy ARN, preventing the boundary document from being weakened.

## Assumptions

- **Single AWS account per environment** — IAM resource scoping is limited to project prefix (`{project_scope_limit_prefix}-*`). Environment-level isolation (dev vs staging vs prod) is assumed to be handled via separate AWS accounts.
- **Bootstrap context** — this module is intended to be called from a bootstrap Terraform root provisioned with admin credentials.
- **IRSA role naming convention** — roles created by the terraform role must follow the `{project_scope_limit_prefix}-*` naming convention for IAM policy conditions to apply correctly.
- **IAM read access** — callers are expected to attach `IAMReadOnlyAccess` (full roles) or `ReadOnlyAccess` (plan roles) via `terraform_role_allowed_managed_policies`.

## Usage

### Human operator role (IAM group trust)

```hcl
module "terraform_role_human" {
  source = "../../modules/iam-terraform-role"

  account_id                 = sensitive(data.aws_caller_identity.current.account_id)
  environment                = "dev"
  region                     = "us-east-2"
  role_name                  = "terraform-dev-human"
  project_scope_limit_prefix = "iss-tracker"
  trust_type                 = "iam"
  role_type                  = "full"

  terraform_role_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess",
  ]

  permission_boundary_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
  ]

  tags = { environment = "dev" }
}
```

### CI apply role (OIDC trust, full permissions, branch-scoped)

```hcl
module "terraform_role_github" {
  source = "../../modules/iam-terraform-role"

  account_id                 = sensitive(data.aws_caller_identity.current.account_id)
  environment                = "dev"
  region                     = "us-east-2"
  role_name                  = "terraform-dev-github"
  project_scope_limit_prefix = "iss-tracker"
  trust_type                 = "oidc"
  role_type                  = "full"
  oidc_provider_arn          = aws_iam_openid_connect_provider.github_actions.arn
  oidc_subjects = [
    "repo:my-org/my-repo:ref:refs/heads/develop",
    "repo:my-org/my-repo:ref:refs/heads/main",
  ]

  terraform_role_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess",
  ]

  permission_boundary_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
  ]

  tags = { environment = "dev" }
}
```

### CI plan role (OIDC trust, read-only, PR-scoped)

```hcl
module "terraform_role_github_plan" {
  source = "../../modules/iam-terraform-role"

  account_id                 = sensitive(data.aws_caller_identity.current.account_id)
  environment                = "dev"
  region                     = "us-east-2"
  role_name                  = "terraform-dev-github-plan"
  project_scope_limit_prefix = "iss-tracker"
  trust_type                 = "oidc"
  role_type                  = "plan"
  oidc_provider_arn          = aws_iam_openid_connect_provider.github_actions.arn
  oidc_subjects = [
    "repo:my-org/my-repo:pull_request",
  ]

  terraform_role_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/ReadOnlyAccess",
  ]

  permission_boundary_allowed_managed_policies = []

  tags = { environment = "dev" }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `account_id` | AWS Account ID. Used to construct IAM ARNs. Marked sensitive. | `string` | — | yes |
| `environment` | Environment name (e.g. `dev`, `prod`). Used in resource names. | `string` | — | yes |
| `region` | AWS region. Used to scope resource ARNs in IAM policies. | `string` | — | yes |
| `role_name` | Name of the IAM role to provision. | `string` | — | yes |
| `project_scope_limit_prefix` | Project name prefix used to scope IAM resource constraints. | `string` | — | yes |
| `trust_type` | Trust principal type: `iam` or `oidc`. | `string` | `"iam"` | no |
| `role_type` | Role permission level: `full` (inline IAM write policy) or `plan` (read-only, no inline policy). | `string` | `"full"` | no |
| `oidc_provider_arn` | ARN of the GitHub Actions OIDC provider. Required when `trust_type = "oidc"`. | `string` | `""` | no |
| `oidc_subjects` | List of OIDC subject claim values to trust. Required when `trust_type = "oidc"`. | `list(string)` | `[]` | no |
| `terraform_role_allowed_managed_policies` | List of AWS managed policy ARNs to attach to the role. | `list` | `[]` | no |
| `permission_boundary_allowed_managed_policies` | List of AWS managed policy ARNs the role may attach to IRSA roles it creates. | `list` | `[]` | no |
| `tags` | Tags to attach to provisioned resources. | `map` | `{}` | no |

## Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `role_name` | Name of the IAM role | no |
| `role_arn` | ARN of the IAM role | yes |
| `group_name` | Name of the IAM group (empty string when `trust_type = "oidc"`) | no |
| `permission_boundary_arn` | ARN of the permissions boundary policy | yes |