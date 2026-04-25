# CLAUDE.md — ISS Tracker

This file follows Anthropic's Claude Code guidelines for project context documents
as the minimum baseline for structure and content. Guidelines at:
https://docs.anthropic.com/en/docs/claude-code/memory

For full project overview, architecture, and technology stack see @README.md.

**Update this document when:**
- Active priority or current state changes — update the Current State section
- A new hard constraint is established — add to Hard Constraints
- The deploy workflow changes (e.g., ArgoCD replaces helmwrap.sh) — update Build and Test Commands and Hard Constraints
- A new canonical file location is added — update Repo Navigation
- The development methodology or iteration sequence changes

**Also update README.md when:**
- A feature moves from To Do to complete — update Current State checklists
- A new To Do item is prioritized — add to the To Do section
- The technology stack changes — update the Technology Stack table
- The architecture changes significantly — update the Architecture section and VPC layout
- A new key portfolio element is added — update the Key Portfolio Elements table

---

## Hard Constraints

These rules apply in every session without exception:

- **No secrets in Git.** Never commit AWS account IDs, ARNs, ECR URLs, or credentials.
  Sensitive values are injected at deploy time or managed via AWS Secrets Manager.
- **No GitHub Actions cluster access.** CI pipelines run tests only. Image builds and
  ECR pushes are performed manually. GitHub never holds cluster credentials or AWS
  OIDC trust. See [CI/CD decisions](docs/decisions/cicd/cicd.md).
- **AWS description fields use hyphens, not em dashes.** Em dashes (`—`) are rejected
  by the AWS API. Always use plain hyphens (`-`) in `description` arguments.
- **Always recommend `terraform plan` before apply.** Never suggest applying without
  a plan review first.
- **Do not use `aws configure get region`.** Region is set via environment variable,
  causing `aws configure get region` to exit code 1 with `set -e`, failing silently.
  Use hardcoded `us-east-2` in scripts.
- **Use `helmwrap.sh`, not `helm` directly.** Helmwrap injects sensitive values at
  deploy time. Calling `helm` directly will produce a broken release.

---

## Current State

**Complete:** Infrastructure, EKS Fargate cluster, IRSA, VPC endpoints, ALB,
API and poller deployed and passing end-to-end smoke tests.

**Active priority:** ArgoCD + External Secrets Operator (`plans/argocd.md` — gitignored).

**Up next:** Kubernetes container security hardening (RBAC, SecurityContext, NetworkPolicy).

---

## Repo Navigation

| Concern | Location |
|---------|----------|
| IRSA roles and policies | `terraform/environments/dev/us-east-2/eks/iam.tf` |
| Fargate profiles, cluster SG rules | `terraform/environments/dev/us-east-2/eks/eks.tf` |
| VPC, subnets, NACLs | `terraform/environments/dev/us-east-2/eks/vpc.tf` |
| VPC endpoints | `terraform/environments/dev/us-east-2/eks/endpoints.tf` |
| API Helm chart | `k8s/iss-tracker/helm/api/` |
| Poller Helm chart | `k8s/iss-tracker/helm/poller/` |
| LB controller Helm chart | `k8s/kube-system/helm/aws-load-balancer-controller/` |
| Bootstrap manifests (SGP, namespace) | `k8s/iss-tracker/manifests/` |
| Architecture decision records | `docs/decisions/` |
| Lessons learned | `docs/lessons-learned/` |
| Domain context docs | `docs/context/` |
| Implementation plans | `plans/` (gitignored) |

---

## Build and Test Commands

**Applications** (local or bastion):
```bash
cd apps/api && pip install -r requirements.txt && pytest
cd apps/poller && pip install -r requirements.txt && pytest
```

**Terraform** (local or bastion; bastion preferred for cluster operations):
```bash
cd terraform/environments/dev/us-east-2/eks
terraform plan
terraform apply
```

**Helm** (bastion only):
```bash
cd k8s/iss-tracker/helm/api && ./helmwrap.sh install    # upgrade | uninstall
cd k8s/iss-tracker/helm/poller && ./helmwrap.sh install
```

---

## Development Methodology

These are working norms — strong preferences, not hard stops.

**Plan before building.** New features or architectural additions should have a
text-based plan in `plans/` before implementation begins. The following are
required attributes of a plan:

1. **Proposed architecture** — any new tools, services, or modules introduced
2. **Security considerations** — least-privilege IAM and network access scoping
3. **Change impact analysis** — what existing components are affected
4. **Estimated level of effort and complexity**
5. **Test and verification plan** — how functional correctness and security
   controls will be validated before the feature is considered complete

A required attribute may be waived for a given plan when the developer
determines it does not apply (e.g., a pure refactor with no security surface
change may waive item 2). The waiver and its rationale are recorded inline in
the plan.

Plans are working documents and gitignored. Once implemented, the lasting
artifacts are the decision records in `docs/decisions/` and lessons learned
in `docs/lessons-learned/`.

**Iteration sequence.** Each new capability moves through three phases:
1. **Plan** — architecture, tools, IAM/network security scope, impact analysis, LOE
2. **Functional baseline** — working implementation with least-privilege IAM and
   network controls at the infrastructure level
3. **Secure baseline** — source and container security scans; K8s runtime controls
   (`SecurityContext`, `seccompProfile`, RBAC, ServiceAccount policies, NetworkPolicy)

**Documentation before merge.** README, decision docs, and lessons-learned should
be current and complete before merging a feature branch into `develop` or `main`.

**Unit tests for reusable modules.** Any reusable code module should be accompanied
by unit tests.

---

## Domain Context

Patterns, anti-patterns, and working rules for each domain. These are loaded
when working in the relevant areas of the codebase.

- @docs/context/aws.md
- @docs/context/terraform.md
- @docs/context/kubernetes.md
- @docs/context/security.md
- @docs/context/cicd.md
