# CI/CD Context — ISS Tracker

Patterns, anti-patterns, and constraints for CI/CD in this project.

**Update this document when:**
- ArgoCD goes live — update the manual operations table; add ArgoCD sync to the deploy workflow
- A new workflow is added — update the CI workflow table
- The branch strategy changes
- The core CI/CD constraint is revisited (e.g., if the repo moves to private)

---

## Core Constraint

**GitHub Actions has no AWS credentials and no cluster access.** This project
uses a public repository — all workflow logs are publicly visible. AWS tooling,
Terraform, and third-party actions can emit account IDs, ARNs, endpoint URLs,
and other sensitive values in log output regardless of masking or suppression
attempts. Granting CI/CD any AWS or Kubernetes access on a public repository
cannot be made safe. This is a hard, permanent constraint.

See `docs/decisions/cicd/cicd.md` for full rationale.

---

## What CI Does

CI pipelines are scoped to build and test only:

| Workflow | Trigger | Actions |
|----------|---------|---------|
| `api-ci.yml` | Push to non-`DEBUG/**` branches touching `apps/api/**` | Lint, unit tests |
| `poller-ci.yml` | Push to non-`DEBUG/**` branches touching `apps/poller/**` | Lint, unit tests |
| `terraform-dev-ci.yml` | Push/PR on `develop` touching terraform | `terraform validate`, `tfsec`, Checkov |
| `terraform-bootstrap-ci.yml` | Push/PR touching bootstrap terraform | `terraform validate`, Checkov |

CI never builds container images, pushes to ECR, or applies terraform.

---

## What CI Does Not Do

- No `terraform plan` or `terraform apply`
- No `docker build` or `docker push`
- No `helm install` or `helm upgrade`
- No `kubectl` commands
- No AWS credential configuration of any kind

---

## Manual Operations

All deployment and infrastructure operations are performed manually:

| Operation | Who | How |
|-----------|-----|-----|
| Container image build + push | Developer | Local or bastion, manual |
| Terraform apply | Developer | Local or bastion |
| Helm install / upgrade | Developer | Bastion via `helmwrap.sh` |
| kubectl operations | Developer | Bastion |

---

## Branch Strategy

| Branch | Purpose | CI trigger |
|--------|---------|------------|
| `main` | Production-ready state | Terraform prod CI (when prod exists) |
| `develop` | Integration branch for dev | Terraform dev CI on merge |
| `feature/*` | Feature development | App and terraform CI on push |
| `DEBUG/**` | Debug branches | Ignored by all CI pipelines |

`DEBUG/**` branches are excluded from all push triggers to prevent CI noise
during active debugging sessions.

---

## Patterns

- Keep CI fast — lint and unit tests only; no integration tests that require
  live AWS resources
- Workflow files are scoped with `paths` filters so only relevant pipelines
  trigger on a given change
- Static analysis (Checkov, tfsec) runs in CI; findings must be resolved or
  explicitly suppressed with rationale before merging

---

## Anti-patterns

- **Never add AWS credentials to GitHub Actions secrets** — not even read-only
  or scoped credentials; the public log exposure risk applies regardless of
  permission scope
- **Never add `kubectl` or `helm` steps to CI workflows**
- **Never use `DEBUG/**` branch names for non-debug work** — these branches
  are ignored by all CI pipelines and changes will not be validated
- **Never merge to `develop` or `main` with open Checkov or tfsec findings**
  that lack documented suppressions