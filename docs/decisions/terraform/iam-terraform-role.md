# IAM Terraform Roles — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## terraform-dev IAM role: privilege escalation prevention

### The problem
The `terraform-dev` role needs IAM permissions to create IRSA roles for Kubernetes pods. But any role that can create roles and attach policies is a potential privilege escalation vector — it could create a new role, attach `AdministratorAccess` to it, assume it, and effectively become an admin. This is a well-known IAM security problem that had to be solved carefully.

### Escalation pathway 1: unrestricted IAMFullAccess
Attaching `IAMFullAccess` as a managed policy was rejected because it provides a direct privilege escalation path — terraform-dev could create any role with any permissions, including admin-level access. `IAMFullAccess` on an automation role is a red flag in any security review.

### Escalation pathway 2: CreateRole + AttachRolePolicy without constraints
Replacing `IAMFullAccess` with a custom inline policy scoped to `iam:CreateRole` and `iam:AttachRolePolicy` still left an escalation path. Even with resource scoped to `iss-tracker-*` roles, the role could:
1. Create a new `iss-tracker-admin` role
2. Attach `AdministratorAccess` (an AWS managed policy) to it
3. Assume that role and gain full admin access

### Escalation pathway 3: AttachRolePolicy without policy scoping
Scoping `iam:AttachRolePolicy` to project roles (`iss-tracker-*`) but not restricting *which policies* can be attached still allowed attaching any AWS managed policy including `AdministratorAccess`. The fix was adding a condition on `iam:PolicyARN` restricting attachments to `iss-tracker-*` named policies and a specific allowlist of AWS managed policies (`AmazonDynamoDBFullAccess`, `AmazonEC2ContainerRegistryFullAccess`).

### Solution: permissions boundary + scoped inline policy
The final approach uses two mechanisms in combination:

**1. Permissions boundary (`iss-tracker-*-boundary`)**
A boundary policy is attached to every role terraform-dev creates. The boundary caps the *maximum* permissions a role can ever exercise — regardless of what policies are attached to it. Even if `AdministratorAccess` were attached to an IRSA role, the boundary limits it to only the services defined in the boundary document (DynamoDB, ECR, CloudWatch Logs, EKS). IAM actions are explicitly absent from the boundary.

**2. Boundary enforcement via condition**
The `iam:CreateRole` allow in the inline policy has a condition requiring `iam:PermissionsBoundary` to equal the boundary ARN. This means the role can *only* create roles if it attaches the boundary in the same API call — it cannot create unbounded roles.

**3. Deny statements protecting the boundary**
Two deny statements prevent the role from undermining its own controls:
- `DenyPermissionsBoundaryDeletion` — prevents removing the boundary from roles it manages
- `DenyPolicyChange` — prevents creating new versions of the boundary policy or changing the default version, which would allow weakening the boundary document itself

### IAMReadOnlyAccess as managed policy
Rather than listing individual read actions (`iam:GetRole`, `iam:ListRolePolicies`, etc.) in the inline policy, `IAMReadOnlyAccess` is attached as a managed policy. This is cleaner and ensures Terraform can read IAM state for plan/apply without maintaining a manual list of read actions.

### Result
The terraform roles can create and manage IRSA roles scoped to the `iss-tracker-*` prefix, attach a controlled set of policies to them, but cannot escalate privileges beyond what the boundary permits. The deny statements ensure the boundary cannot be removed or weakened by the role itself.

## IAM resource scoping: project prefix only, not environment

### What was considered
During development, environment-level scoping was explored — adding an environment suffix (`iss-tracker-*-dev`) to all IAM resource ARNs in the inline policy and permissions boundary. This would prevent `terraform-dev` from managing staging or prod resources within the same AWS account.

### Why it was not implemented
AWS managed policies (e.g. `AmazonDynamoDBFullAccess`, `AmazonEKSClusterPolicy`) are account-scoped — they cannot be restricted to specific resource name patterns. Even with environment-scoped IAM resource ARNs in the inline policy, the managed policies attached to the terraform role would still grant access to all resources in the account. Environment isolation via resource naming only works when all permissions are customer-managed, which would require rewriting all seven managed policies as custom inline policies — significant complexity with diminishing portfolio value.

### The correct solution at scale
Proper environment isolation is achieved through **separate AWS accounts per environment**, not resource naming conventions within a single account. AWS Organizations + Control Tower is the standard approach. Each environment account has its own IAM boundary and the cross-account blast radius is zero by design.

### Accepted tradeoff for this project
IAM resource scoping is limited to project prefix (`iss-tracker-*`) only. This prevents the terraform role from managing IAM resources outside the project but does not enforce environment isolation within the same account. This is a documented and accepted tradeoff given:
- The project uses a single AWS account for cost control (daily `terraform destroy`)
- The correct multi-account solution is documented and understood
- The privilege escalation controls (boundary, deny statements) remain fully intact

In production this would be solved with separate accounts, not workarounds.

## IAM group for role assumption
An IAM group (`terraform-dev-human-users`) is used to control which users can assume the human terraform role, rather than listing individual user ARNs in the role trust policy. The trust policy allows the entire account root as principal, and the group inline policy grants `sts:AssumeRole` to members. This pattern means adding or removing access is a group membership change, not a trust policy edit — simpler operationally and avoids trust policy churn as team membership changes.

## Separate roles per principal type and permission level

Three terraform IAM roles are provisioned, each with a distinct trust policy and permission scope:

| Role | Trust | Boundary | Used for |
|------|-------|----------|----------|
| `terraform-dev-human` | IAM group (account root) | Yes | Human operators running plan/apply locally |
| `terraform-dev-github` | OIDC, `develop` ref only | Yes | CI apply jobs after merge to protected branch |
| `terraform-dev-github-plan` | OIDC, `pull_request` subject | No | CI plan jobs on pull requests (read-only) |

### Why separate roles matter
CloudTrail logs identify changes by role ARN. Separate roles give instant traceability — a change made by `terraform-dev-github` was an automated CI apply; a change made by `terraform-dev-human` was a manual operator action. If a security incident occurs, the blast radius and investigation scope are immediately narrower.

### The plan role: security boundary for PRs
The OIDC `sub` claim for pull requests is `repo:{org}/{repo}:pull_request` — it does not include a branch name. This means any branch in the repository can open a PR and trigger a workflow. Giving the full apply role to PR workflows would allow untrusted feature branches to assume a role with infrastructure write permissions.

The `terraform-dev-github-plan` role solves this:
- Trust policy only allows the `pull_request` OIDC subject
- No inline IAM write policy — the role carries no write permissions at all
- Even if a compromised PR workflow tried to apply, it has no write surface

The full `terraform-dev-github` role trust policy is restricted to `refs/heads/develop` only — only merges to the protected branch can assume it.

### Why no permissions boundary on the plan role
The permissions boundary exists to cap the blast radius of IAM write operations — specifically to prevent a role from creating unbounded child roles that escalate privilege. The plan role has no `iam:Create*` or `iam:Attach*` permissions at all. With no IAM write surface, there is no escalation vector to constrain, so attaching a boundary would add complexity without adding security value.

## Module refactor: four purpose-specific modules

### The problem with a single module
The original `iam-terraform-role` module used `trust_type` and `role_type` input variables to conditionally switch between IAM and OIDC trust policies and between full and plan permission sets. This required:
- Conditional locals for trust policy construction
- `count` expressions on resources controlled by `role_type`
- Optional variables that only applied to one trust type (`oidc_provider_arn`, `oidc_subjects`, `account_id`)

Each code path was valid for one configuration and dead weight for the other. A reader auditing the module had to mentally trace every conditional to understand what actually gets provisioned for a given input combination. As the number of role types grew, the complexity compounded.

### Solution: one module per trust type and permission level
The single module was replaced with four purpose-specific modules:

| Module | Trust policy | Boundary | IAM write |
|--------|-------------|----------|-----------|
| `iam-permission-boundary` | — | Creates policy | — |
| `iam-terraform-role-human` | `sts:AssumeRole` (AWS principal) | Required input | Optional inline |
| `iam-terraform-role-oidc-plan` | `sts:AssumeRoleWithWebIdentity` | None | Optional inline |
| `iam-terraform-role-oidc-apply` | `sts:AssumeRoleWithWebIdentity` | Required input | Optional inline |

Each module contains exactly one trust policy type — no conditionals, no dead code paths. The full behavior of each module is visible without tracing variable branches.

### Design principle: modules handle structure, callers supply all policy content
All IAM policy documents (boundary policy, inline policies) are defined by the calling root using `jsonencode()` locals and passed in as `string` variables. Modules wire the policy to the correct resource but never construct policy content themselves.

This keeps policy intent visible at the root level — the place where environment-specific values (account IDs, region, resource prefixes) are naturally available. It also means the policy documents can be reviewed in one place alongside the managed policy ARNs and other role configuration, rather than being split across module and caller.

### Separate bootstrap roots per role
Each role module gets its own bootstrap root under `terraform/environments/dev/global/bootstrap/`. The apply order is:

1. `s3-tfstate` — state bucket (prerequisite for all other roots)
2. `iam-terraform-role-human` — boundary + human role (no external dependencies)
3. `iam-oidc-provider-github` — GitHub Actions OIDC provider (prerequisite for OIDC role roots)
4. `iam-terraform-role-oidc-plan` — plan role (depends on OIDC provider)
5. `iam-terraform-role-oidc-apply` — boundary + apply role (depends on OIDC provider)

Separate roots mean each role's state is isolated. Destroying or recreating one role does not touch the others.

## Sensitive outputs for ARNs
`role_arn` and `permission_boundary_arn` outputs are marked `sensitive = true`. ARNs contain the AWS account ID, which should not appear in `terraform plan` or `terraform apply` console output — especially important for public repos where GitHub Actions logs are publicly visible. Sensitive outputs are still fully usable in Terraform expressions and module composition.