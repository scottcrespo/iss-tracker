# Terraform Context — ISS Tracker

Patterns, anti-patterns, and known gotchas for Terraform usage in this project.

**Update this document when:**
- A new root module is added — update the file organization conventions
- A new state drift incident is discovered — add to the known gotchas
- Module pinning or sourcing conventions change
- A new Checkov suppression pattern is established
- A new governance-verification test pattern is established for modules

---

## Module Conventions

**Pre-built vs DIY split.** Use `terraform-aws-modules` for well-understood
infrastructure that is not the learning focus (VPC, EKS cluster). Write
caller-defined resources for anything security-sensitive — IAM policies, security
groups, NACLs. Modules provision structure; root modules define behavior.

**Pin module sources to commit SHAs, not tags.** Tags are mutable and can be
moved. All module `source` references use `?ref=<full-commit-sha>` to guarantee
reproducibility.

**IAM policy content is always caller-defined.** No module in this codebase
defines what an identity is allowed to do. See `docs/context/aws.md` IAM
Governance rules.

**Module-provisioned security groups are caller-toggleable.** Any module
that creates a security group exposes the SG as caller-toggleable via two
coordinated inputs:

1. `create_<name>_security_group` — boolean, default `true`. Gates the
   `aws_security_group` resource and every rule whose `security_group_id`
   attaches to it (bundled as one unit, one flag per SG not per rule).
2. `<name>_security_group_id` — string, default `null`. When the create
   flag is `false`, the caller supplies an externally-managed SG ID here.

Exactly one path must be selected per SG, enforced by two `validation`
blocks on the ID variable:

```hcl
validation {
  condition     = !(var.create_<name>_security_group == false && var.<name>_security_group_id == null)
  error_message = "When create_<name>_security_group is false, <name>_security_group_id must be provided."
}
validation {
  condition     = !(var.create_<name>_security_group == true && var.<name>_security_group_id != null)
  error_message = "When create_<name>_security_group is true, <name>_security_group_id must be null - the module manages the SG."
}
```

The module resolves the SG ID through a local that returns whichever
path the caller selected:

```hcl
local.<name>_sg_id = var.create_<name>_security_group ? one(aws_security_group.<name>[*].id) : var.<name>_security_group_id
```

All internal references - the `vpc_security_group_ids` on EC2 instances,
the `security_group_ids` on endpoints, the `source_security_group_id` on
cross-reference rules - consume the local. They do not care which path
produced the ID, so every combination of flags across multiple SGs in the
module works correctly. Cross-reference rules between two module-managed
SGs require no compound gates because the locals always resolve.

Tests must cover the default path (SGs created), the external path
(SGs skipped, external IDs flow through to downstream resources and
outputs), and the validation failures (one path must be selected).

See `terraform/modules/bastion/` for the reference implementation and
`terraform/modules/bastion/tests/bastion.tftest.hcl` for the test
pattern.

**Modules accepting IAM policy content must verify ownership via `terraform test`.**
Any module that accepts a policy document (or map of documents) as input must
include test cases asserting:

1. **Content equality** — `jsondecode(attached_policy) == jsondecode(input_policy)`
   for each policy passed in. Proves the module does not rewrite, wrap, or
   re-serialize the caller's policy document.
2. **Count equality** — `length(attached_policies) == length(input_policies)`.
   Proves the module does not attach policies the caller did not specify.

Together these verify the IAM Governance rule at the module level: policy
content flows through the module unchanged, and the module contributes no
policy content of its own. Tests run under `mock_provider "aws"` so no AWS
credentials or live resources are required. See
`terraform/modules/bastion/tests/` for the reference implementation.

**File organization within a root module:**

| File | Contents |
|------|----------|
| `locals.tf` | Shared local values (cluster name, VPC CIDR, etc.) |
| `vpc.tf` | VPC, subnets, NACLs, route tables |
| `eks.tf` | EKS cluster, Fargate profiles, cluster/node SG rules |
| `iam.tf` | All IAM roles and policies |
| `endpoints.tf` | VPC endpoints and endpoint security groups |
| `bastion.tf` | Bastion host and Instance Connect Endpoint |
| `outputs.tf` | Root module outputs |
| `variables.tf` | Input variables |

Security groups are defined in the file closest to the resource they protect —
endpoint SGs in `endpoints.tf`, cluster SGs in `eks.tf`.

---

## Patterns

- Always run `terraform plan` before apply and review the diff before proceeding
- Use `locals` for any value referenced more than once
- Use `for_each` over `count` for resources with meaningful identity — `count`
  produces index-based addressing that breaks when items are removed mid-list
- Checkov static analysis suppressions (`#checkov:skip`) must include an inline
  rationale explaining why the skip is justified for this specific resource
- Remote state uses S3 native state locking — never use local state for
  environment roots

---

## Anti-patterns

- **Never `apply -auto-approve`** in any environment root
- **Never commit `terraform.tfstate` or `.tfvars` files** containing sensitive
  values to Git
- **Never use mutable module source references** (`latest`, branch names, or
  moveable tags) — always pin to a commit SHA
- **Never define IAM policy documents inside a module** — policy content belongs
  in the root module that owns the trust relationship
- **Never skip Checkov without a documented rationale** — undocumented skips are
  indistinguishable from overlooked findings

---

## Known Gotchas

**State drift is silent.** Security group rules and NACL entries can exist in
terraform config but be absent from actual AWS state after an interrupted or
partially-failed apply. `terraform plan` will report "no changes" while traffic
is still being rejected. When behavior doesn't match config, verify with AWS CLI
before adding workarounds. See `docs/lessons-learned/private-eks-fargate-debugging.md`.

**Checkov false positives on module-internal attachments.** Resources created
inside third-party modules (e.g., VPC endpoint ENIs) cannot be traced by Checkov
from the calling module. Use `#checkov:skip` with a rationale on the resource
that owns the attachment, not the module call.

**`terraform-aws-modules/eks` creates the cluster SG automatically.** The cluster
security group ID is exposed as `module.eks.cluster_security_group_id`. Additional
rules (e.g., DNS ingress from Fargate pods) must be added as separate
`aws_security_group_rule` resources targeting this ID — not via the module's
`cluster_security_group_additional_rules` input, which has caused state drift
in this project.