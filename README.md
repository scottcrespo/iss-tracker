# ISS Tracker

A full-stack cloud-native application that tracks the real-time position of the International Space Station. Built as a portfolio project to demonstrate production-grade platform and DevSecOps engineering practices across infrastructure, CI/CD, containerization, and Kubernetes.

---

## Purpose

This project exists to demonstrate end-to-end platform engineering skills in a realistic context — not just "infrastructure that works" but infrastructure designed with the same principles applied in production environments: security boundaries, least-privilege IAM, private networking, GitOps workflows, and documented architectural decisions.

It is intentionally over-engineered relative to the application's simplicity. The ISS position API is a vehicle for the real work, which is the platform underneath it.

---

## System Overview

The ISS Tracker consists of two application components backed by fully-private AWS infrastructure:

- **Poller** — a CronJob that fetches the current ISS position from a public API and writes it to DynamoDB
- **API** — a FastAPI service that reads position data from DynamoDB and exposes it over HTTP via an ALB

Both applications run as containers on EKS Fargate inside a private VPC. All AWS service access (ECR, DynamoDB, STS, CloudWatch) is handled through VPC endpoints.

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Cloud | AWS |
| Infrastructure as Code | Terraform |
| Container Orchestration | Amazon EKS (Fargate) |
| Container Registry | Amazon ECR (private) |
| Database | Amazon DynamoDB |
| Load Balancing | AWS Application Load Balancer (via AWS LB Controller) |
| Applications | Python 3.12 (FastAPI, boto3, httpx) |
| CI/CD | GitHub Actions with OIDC authentication |
| Helm | Helm v3 |
| Secret Management | ARN injection at deploy time (no secrets in repo) |

---

## Design Principles

**Least-privilege IAM throughout.** Every IAM role is scoped to the minimum permissions required. IRSA (IAM Roles for Service Accounts) binds Kubernetes service accounts to IAM roles using OIDC federation, scoped with `StringEquals` conditions to exact namespace and service account name. CI/CD roles separate plan and apply permissions.

**No secrets in the repository.** Account IDs, role ARNs, and other sensitive values are injected at deploy time using AWS CLI lookups. The repository is safe to be public.

**Private networking by default.** EKS nodes and Fargate kube-system namespace pods run in intra subnets with no NAT gateway and no internet route. Fargate iss-tracker namespace pods run in private subnet with internet egress route via NAT gateway. All AWS service communication uses VPC endpoints. For resources deployed into intra subnets (as feasible), the absence of an internet route is the primary security control — it makes permissive-looking NACL rules safe in practice.

**IAM policy content is always caller-defined.** Terraform modules provision IAM role structure; the calling root module supplies all policy documents. No module in this codebase defines what an identity is allowed to do.

**Decisions are documented.** Every non-obvious architectural choice has a corresponding decision document explaining the tradeoff, the alternatives considered, and why the chosen approach is correct for this context. See [docs/decisions/](docs/decisions/).

**CI/CD is designed but not wired to live infrastructure.** GitHub Actions logs on public repositories are publicly visible. Terraform, the AWS provider, and third-party actions can all emit AWS account IDs, ARNs, and other sensitive values in log output — from state reads, error messages, and provider debug traces — regardless of stdout suppression attempts. Connecting CI/CD pipelines to a live AWS account from a public repository cannot be made safe without private runners or a private repository. The full CI/CD architecture is implemented and documented: OIDC federation, separate plan/apply roles, manual approval gates, and Terraform plan artifact passing. It is production-ready in design; it is simply not connected to a live account from a public repo. See [CI/CD design decisions](docs/decisions/cicd/cicd.md).

**Infrastructure is reproducible and disposable.** The cluster is designed to be created and destroyed with a single `terraform apply` / `terraform destroy`. This keeps costs low and validates that nothing depends on manual state.

---

## Architecture

```
Internet
    │
    ▼
ALB (public subnets)
    │
    ▼  port 8000
API Pod (private subnet, Fargate)
    │
    ▼
DynamoDB ◄─── Poller CronJob (private subnet, Fargate)
                    │
                    ▼ port 443
              Public ISS API (via NAT gateway)
```

### VPC Layout

The VPC uses three subnet tiers. The split between private and intra is intentional — not all workloads need internet access, and giving every pod a NAT route it doesn't need weakens the security posture.

| Subnet type | CIDR | Used for | Internet egress |
|-------------|------|----------|----------------|
| Public | `10.0.101-103.0/24` | ALB only | Yes (IGW) |
| Private | `10.0.1-3.0/24` | iss-tracker Fargate pods, bastion | Yes (NAT gateway) |
| Intra | `10.0.51-53.0/24` | kube-system Fargate pods | None |

The bastion host lives in the private subnet and uses the NAT gateway for outbound internet (kubectl/helm downloads). No public IP is assigned — EC2 Instance Connect Endpoint proxies SSH to its private IP.

`kube-system` pods (CoreDNS, AWS Load Balancer Controller) run in intra subnets. They only communicate with AWS services via VPC endpoints and have no internet route.

`iss-tracker` pods run in private subnets. The poller requires outbound internet access to reach the public ISS position API; the NAT gateway provides this without exposing pods to inbound connections.

### VPC Endpoints

All AWS service traffic is routed through VPC endpoints. Interface endpoint ENIs are placed in the intra subnets; private subnet pods reach them via VPC-local routing. Gateway endpoints (S3, DynamoDB) are added to both intra and private route tables.

| Endpoint | Type | Purpose |
|----------|------|---------|
| `ecr.api` / `ecr.dkr` | Interface | Container image pulls |
| `s3` | Gateway | ECR layer storage |
| `dynamodb` | Gateway | Application data |
| `sts` | Interface | IRSA token exchange |
| `logs` | Interface | CloudWatch log delivery |
| `eks` | Interface | Cluster API |

### IAM / IRSA

Each workload has a dedicated IAM role scoped to its minimum required permissions:

| Role | Permissions |
|------|------------|
| `iss-tracker-eks-api` | DynamoDB read/write on `iss-tracker-*` tables |
| `iss-tracker-eks-poller` | DynamoDB `PutItem`, `UpdateItem` only |
| `iss-tracker-eks-lb-controller` | ALB/NLB management (AWS reference policy) |

### CI/CD

GitHub Actions workflows authenticate to AWS using OIDC (no long-lived credentials). Plan and apply use separate IAM roles:

- **Plan role** — S3 state read only, triggered on pull requests
- **Apply role** — full infrastructure permissions with permission boundary enforcement, triggered on merge to `develop`

Separate workflow files cover bootstrap infrastructure, application CI, and environment infrastructure.

---

## Repository Structure

```
.
├── apps/
│   ├── api/                    # FastAPI application
│   └── poller/                 # ISS position poller
├── docs/
│   └── decisions/              # Architecture decision records
│       ├── terraform/
│       ├── k8s/
│       ├── apps/
│       └── cicd/
├── k8s/
│   ├── kube-system/            # Namespace: kube-system
│   │   └── helm/
│   │       └── aws-load-balancer-controller/
│   └── iss-tracker/            # Namespace: iss-tracker
│       ├── helm/               # Application Helm charts (in progress)
│       └── manifests/
│           └── security-group/ # SecurityGroupPolicy (SGP for private Fargate pods)
└── terraform/
    ├── environments/
    │   └── dev/
    │       ├── global/bootstrap/   # IAM roles, OIDC provider, state backend
    │       └── us-east-2/
    │           ├── eks/            # VPC, EKS cluster, IAM, endpoints, bastion
    │           ├── ecr/            # Container registries
    │           └── dynamodb/       # Application database
    └── modules/                # Reusable Terraform modules
```

---

## Current State

**Infrastructure — complete**
- [x] S3 remote state with locking
- [x] IAM bootstrap: human role, OIDC provider, plan/apply CI roles with permission boundaries
- [x] VPC with public, private, and intra subnets, explicit NACLs, VPC flow logs
- [x] VPC endpoints for all required AWS services
- [x] EKS cluster (Fargate, private endpoint only)
- [x] IRSA roles for all workloads
- [x] DynamoDB table for ISS position data
- [x] ECR repositories (API, Poller, LB Controller mirror)
- [x] Bastion host with EC2 Instance Connect Endpoint for private cluster access
- [x] AWS Load Balancer Controller installed and running

**Applications — complete**
- [x] Poller application with DynamoDB write, retry logic, Pushgateway integration
- [x] FastAPI application with `/position` and `/positions` endpoints
- [x] Docker images built and pushed to private ECR

**CI/CD — complete**
- [x] GitHub Actions workflows for bootstrap, app, and environment infrastructure
- [x] OIDC-based authentication (no stored AWS credentials)
- [x] Separate plan and apply roles

## To Do

- [ ] Helm chart for API Deployment + Ingress (ALB)
- [ ] Helm chart for Poller CronJob
- [ ] Kubernetes namespace and service account provisioning
- [ ] End-to-end smoke test (poller writes, API reads)
- [ ] Prometheus + Pushgateway for poller heartbeat metrics
- [ ] Grafana dashboard
- [ ] CI pipeline for Helm chart deployment

---

## Key Portfolio Elements

| Artifact | Description |
|----------|-------------|
| [EKS Terraform root](terraform/environments/dev/us-east-2/eks/) | VPC, EKS, IAM, endpoints, bastion — the most complex root module |
| [EKS design decisions](docs/decisions/terraform/eks.md) | Fargate tradeoffs, private networking, S3 gateway endpoint behavior |
| [IAM design decisions](docs/decisions/terraform/iam-terraform-role.md) | OIDC federation, permission boundaries, plan/apply separation |
| [K8s design decisions](docs/decisions/k8s/k8s.md) | Observability on Fargate, Prometheus without DaemonSets |
| [CI/CD design decisions](docs/decisions/cicd/cicd.md) | Branch-per-environment strategy, OIDC auth pattern |
| [API application](apps/api/) | FastAPI, DynamoDB access patterns, dependency injection |
| [Poller application](apps/poller/) | CronJob pattern, retry logic, Pushgateway metrics |
| [Bootstrap Terraform](terraform/environments/dev/global/bootstrap/) | IAM chicken-and-egg solution, OIDC provider provisioning |