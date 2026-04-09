# CI/CD — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## One workflow file per concern

Each application and infrastructure concern has its own workflow file rather than a single monolithic pipeline:

- `poller-ci.yml` — unit tests + image scan for the poller app
- `api-ci.yml` — unit tests + image scan for the API app
- `terraform-dev-ci.yml` — lint/validate/plan/apply for non-bootstrap Terraform roots
- `terraform-bootstrap-ci.yml` — lint/validate only for bootstrap Terraform roots

This keeps each pipeline independently readable and avoids complex conditional logic to selectively skip steps across unrelated concerns. It also means a change to the poller app doesn't trigger Terraform jobs and vice versa — path filtering enforces this boundary.

## Path filtering for monorepo CI

All workflows use `paths` filters so jobs only trigger when the relevant files change. For example, `poller-ci.yml` only runs on changes under `apps/poller/**`. This avoids unnecessary pipeline runs and keeps CI feedback scoped to the change being made.

## Branch-per-environment promotion pattern

CI pipelines follow a branch-per-environment promotion model:

- PR targeting `develop` or `main` → lint/validate/test/plan only, no deployment
- Push to `develop` (merge) → deploy/apply to **dev** environment
- Push to `main` (merge) → deploy/apply to **prod** environment

GitHub Actions has no dedicated "merge" event — a merged PR becomes a `push` event on the target branch, so `push` with a branch filter is the correct trigger for apply/deploy jobs.

This pattern is applied consistently across Terraform, app image builds/deploys, and Kubernetes manifest applies. The same structure is used or templated in every pipeline so the promotion model is immediately recognizable.

**Single-account limitation:** This project uses one AWS account for cost control. The branch-per-environment pattern provides logical separation (separate Terraform roots, separate state files) but not true blast-radius isolation. Proper environment isolation requires separate AWS accounts per environment — that is the correct production solution and is documented in the Terraform decisions.

## PR = validate only, merge = apply

Plan and apply jobs are gated by event type rather than branch alone:

- `if: github.event_name == 'pull_request'` — plan/preview only
- `if: github.event_name == 'push' && (github.ref == 'refs/heads/develop' || github.ref == 'refs/heads/main')` — apply/deploy

This ensures infrastructure and application changes are always reviewed before they are applied. A plan output on the PR gives reviewers visibility into what will change before merge.

## Bootstrap CI separated from non-bootstrap CI

Bootstrap Terraform roots (`s3-tfstate`, `iam-role-terraform-dev`) are covered by a dedicated `terraform-bootstrap-ci.yml` that runs lint and validation only — never plan or apply. These roots require admin credentials and manage resources (the state bucket, the Terraform IAM role) that would break all subsequent automation if accidentally destroyed. Running them in CI introduces unacceptable risk with minimal benefit, since bootstrap roots change rarely.

Non-bootstrap roots live in `terraform-dev-ci.yml` and are designed for full plan/apply automation as roots are provisioned.

## Terraform plan/apply not executed in public CI

Terraform plan and apply jobs are designed and documented in `terraform-dev-ci.yml` but are not connected to a live AWS account in this public repository. The reason: GitHub Actions logs on public repositories are publicly visible, and there is no reliable way to suppress all sensitive output. Terraform, the AWS provider, and action steps can all emit AWS account IDs and ARNs — from state reads, error messages, and provider debug output — regardless of stdout suppression.

The correct production solution is one of:
- **Private runners** (self-hosted or GitHub's larger runners with restricted log visibility)
- **Private repository** where Actions logs are not publicly accessible

The full CI architecture is implemented and documented: IAM roles with OIDC federation, separate plan vs apply roles, and manual approval gates. The design is production-ready — it just isn't wired to a live account from a public repo.

## Terraform apply requires manual approval

When plan/apply jobs are enabled (private repo or private runners), apply jobs reference a GitHub Environment (`dev` or `prod`) configured with required reviewers in repo Settings → Environments. GitHub pauses the apply job after the plan completes and sends an approval notification. The reviewer inspects the plan locally, then approves or rejects. Infrastructure changes are never applied automatically without a human in the loop.

Plan files are saved as a binary (`terraform plan -out=tfplan`) and passed between jobs as a GitHub Actions artifact. The apply job downloads the artifact and runs `terraform apply -input=false tfplan`, guaranteeing it executes exactly what was reviewed rather than re-planning from scratch. On a private repo or with private runners, GitHub Actions artifacts are not publicly accessible so this is safe — no S3 indirection needed.

## Trivy for container image scanning

Container images are scanned with Trivy (`aquasecurity/trivy-action`) as part of the `build-and-scan` job in both app pipelines. Trivy is open source, integrates directly as a GitHub Action, and covers OS and language-level CVEs. The scan is configured to:

- Fail the job (`exit-code: 1`) on `HIGH` or `CRITICAL` severity findings
- Skip unfixed vulnerabilities (`ignore-unfixed: true`) to avoid blocking on CVEs with no available patch

The `build-and-scan` job runs after `test` passes (`needs: test`), so a failing test suite doesn't waste time building and scanning an image that would be rejected anyway.

## Image tagged with git SHA

Docker images are tagged with `${{ github.sha }}` rather than `latest` or a semantic version. SHA tagging makes every image uniquely traceable to the exact commit that produced it, which is important for rollback and audit. A `latest` tag would be ambiguous in a CI context where multiple PRs may be building images concurrently.