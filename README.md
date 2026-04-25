# ISS Tracker

A full-stack cloud-native application that tracks the real-time position of the International Space Station. Built as a portfolio project to demonstrate production-grade platform and DevSecOps engineering practices across infrastructure, CI/CD, containerization, and Kubernetes.

---

## Contents

- [Purpose](#purpose)
- [System Overview](#system-overview)
- [Technology Stack](#technology-stack)
- [Design Principles](#design-principles)
- [Architecture](#architecture)
  - [VPC Layout](#vpc-layout)
  - [VPC Endpoints](#vpc-endpoints)
  - [IAM / IRSA](#iam--irsa)
  - [CI/CD](#cicd)
- [Repository Structure](#repository-structure)
- [Current State](#current-state)
- [To Do](#to-do)
- [Key Portfolio Elements](#key-portfolio-elements)

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
| GitOps | ArgoCD (automated sync from Git, no CI cluster access) |
| Secrets Management | AWS Secrets Manager + External Secrets Operator (ESO) |
| Helm | Helm v3 |
| Container Security Scanning | Trivy |
| Infrastructure Security Scanning | Checkov, tfsec |

---

## Design Principles

**Least-privilege IAM throughout.** Every IAM role is scoped to the minimum permissions required. IRSA (IAM Roles for Service Accounts) binds Kubernetes service accounts to IAM roles using OIDC federation, scoped with `StringEquals` conditions to exact namespace and service account name. CI/CD roles separate plan and apply permissions.

**No secrets in the repository.** Account IDs, role ARNs, ECR URLs, and credentials are never committed. Sensitive values are stored in AWS Secrets Manager and surfaced into the cluster by External Secrets Operator. The repository is safe to be public.

**Private networking by default.** EKS nodes and Fargate kube-system namespace pods run in intra subnets with no NAT gateway and no internet route. Fargate iss-tracker namespace pods run in private subnet with internet egress route via NAT gateway. All AWS service communication uses VPC endpoints. For resources deployed into intra subnets (as feasible), the absence of an internet route is the primary security control — it makes permissive-looking NACL rules safe in practice.

**IAM policy content is always caller-defined.** Terraform modules provision IAM role structure; the calling root module supplies all policy documents. No module in this codebase defines what an identity is allowed to do.

**Decisions are documented.** Every non-obvious architectural choice has a corresponding decision document explaining the tradeoff, the alternatives considered, and why the chosen approach is correct for this context. See [docs/decisions/](docs/decisions/).

**CI is implemented but not wired to live infrastructure; CD is live via ArgoCD.** The continuous delivery side is fully operational: ArgoCD runs inside the cluster and polls this repository, automatically syncing changes to `develop` into the cluster without any cluster credentials living in GitHub. The continuous integration side (GitHub Actions → AWS) is a deliberate architectural choice, not an omission. Public repository workflow logs are publicly visible, and AWS tooling can emit account IDs, ARNs, and other sensitive values regardless of suppression attempts. The full CI architecture is implemented in Terraform and documented — OIDC federation, separate plan/apply roles, permission boundaries — and is production-ready in design. It is simply not connected to a live account from a public repo. See [CI/CD design decisions](docs/decisions/cicd/cicd.md).

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

| Subnet type | CIDR | Aggregate | Used for | Internet egress |
|-------------|------|-----------|----------|----------------|
| Public | `10.0.192-194.0/24` | `10.0.192.0/18` | ALB only | Yes (IGW) |
| Private | `10.0.0-2.0/24` | `10.0.0.0/17` | iss-tracker Fargate pods, bastion | Yes (NAT gateway) |
| Intra | `10.0.128-130.0/24` | `10.0.128.0/18` | kube-system Fargate pods | None |

The bastion host lives in the private subnet and uses the NAT gateway for outbound internet (kubectl/helm downloads). No public IP is assigned — EC2 Instance Connect Endpoint proxies SSH to its private IP.

`kube-system` pods (CoreDNS, AWS Load Balancer Controller) run in intra subnets. They only communicate with AWS services via VPC endpoints and have no internet route.

`iss-tracker` pods run in private subnets. The poller requires outbound internet access to reach the public ISS position API; the NAT gateway provides this without exposing pods to inbound connections.

### VPC Endpoints

All AWS service traffic is routed through VPC endpoints. Interface endpoint ENIs are placed in the intra subnets; private subnet pods reach them via VPC-local routing. Gateway endpoints (S3, DynamoDB) are added to both intra and private route tables.

| Endpoint | Type | Purpose |
|----------|------|---------|
| `ecr.api` / `ecr.dkr` | Interface | Container image pulls |
| `s3` | Gateway | ECR image layer storage |
| `dynamodb` | Gateway | Application data (API and poller) |
| `sts` | Interface | IRSA token exchange (all workloads) |
| `logs` | Interface | CloudWatch log delivery |
| `eks` | Interface | Cluster API communication |
| `elasticloadbalancing` | Interface | ALB/NLB management (LB controller) |
| `ec2` | Interface | Subnet and SG discovery (LB controller) |

### IAM / IRSA

Each workload has a dedicated IAM role scoped to its minimum required permissions:

| Role | Permissions |
|------|------------|
| `iss-tracker-eks-api` | DynamoDB read/write on `iss-tracker-*` tables |
| `iss-tracker-eks-poller` | DynamoDB `PutItem`, `UpdateItem` only |
| `iss-tracker-eks-lb-controller` | ALB/NLB management (AWS reference policy) |
| `iss-tracker-eks-eso` | `secretsmanager:GetSecretValue` on `iss-tracker/*` secrets only |

### CI/CD

**Continuous delivery** is live via ArgoCD. ArgoCD runs inside the cluster and polls this repository; merges to `develop` are automatically synced to the cluster. The cluster reaches out to Git — GitHub never holds cluster credentials or AWS access.

**Continuous integration** via GitHub Actions covers linting, unit tests, Terraform validation, and static security analysis (Checkov, tfsec). The GitHub Actions → AWS authentication architecture is fully implemented in Terraform for demonstration purposes — OIDC federation, separate plan/apply IAM roles, permission boundaries — but is intentionally not connected to a live AWS account. Public repository workflow logs are publicly visible and cannot safely carry AWS credentials or emit account metadata. See [CI/CD design decisions](docs/decisions/cicd/cicd.md).

The OIDC plan/apply role split:
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
│   ├── argocd/                 # Namespace: argocd
│   │   ├── apps/               # ArgoCD Application manifests + deploy.sh
│   │   ├── helm/               # ArgoCD Helm chart and values
│   │   └── manifests/          # ExternalSecret resources for ESO
│   ├── kube-system/            # Namespace: kube-system
│   │   └── helm/
│   │       └── aws-load-balancer-controller/
│   └── iss-tracker/            # Namespace: iss-tracker
│       ├── helm/               # Application Helm charts
│       └── manifests/
│           └── security-group/ # SecurityGroupPolicy (SGP for private Fargate pods)
└── terraform/
    ├── environments/
    │   └── dev/
    │       ├── global/bootstrap/   # IAM roles, OIDC provider, state backend
    │       └── us-east-2/
    │           ├── eks/            # VPC, EKS cluster, IAM, endpoints
    │           ├── bastion/        # Bastion host and EICE (separate root)
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

**Kubernetes — complete**
- [x] Helm chart for API Deployment + Ingress (ALB)
- [x] Helm chart for Poller CronJob
- [x] Kubernetes namespace and service account provisioning
- [x] End-to-end smoke test (poller writes, API reads)

**CI/CD — complete**
- [x] GitHub Actions workflows for bootstrap, app, and environment infrastructure
- [x] OIDC-based authentication (no stored AWS credentials)
- [x] Separate plan and apply roles
- [x] ArgoCD GitOps loop — automated sync on `develop` push; External Secrets Operator for secrets management; no CI cluster access, no secrets in Git

## To Do

- [ ] Kubernetes container security hardening — RBAC, ServiceAccount policies, SecurityContext (`runAsNonRoot`, `readOnlyRootFilesystem`, drop capabilities)
- [ ] Prometheus + Pushgateway for poller heartbeat metrics
- [ ] Grafana dashboard

---

## Key Portfolio Elements

| Artifact | Description |
|----------|-------------|
| [EKS Terraform root](terraform/environments/dev/us-east-2/eks/) | VPC, EKS, IAM, endpoints — the most complex root module |
| [Bastion Terraform root](terraform/environments/dev/us-east-2/bastion/) | Bastion host and EICE; reads EKS remote state; separate lifecycle from cluster |
| [EKS design decisions](docs/decisions/terraform/eks.md) | Fargate tradeoffs, private networking, S3 gateway endpoint behavior |
| [IAM design decisions](docs/decisions/terraform/iam-terraform-role.md) | OIDC federation, permission boundaries, plan/apply separation |
| [K8s design decisions](docs/decisions/k8s/k8s.md) | Observability on Fargate, Prometheus without DaemonSets |
| [CI/CD design decisions](docs/decisions/cicd/cicd.md) | Branch-per-environment strategy, OIDC auth pattern |
| [ArgoCD design decisions](docs/decisions/cicd/argocd.md) | GitOps loop, ESO secrets injection, deploy.sh pattern, deferred AVP |
| [API application](apps/api/) | FastAPI, DynamoDB access patterns, dependency injection |
| [Poller application](apps/poller/) | CronJob pattern, retry logic, Pushgateway metrics |
| [Bootstrap Terraform](terraform/environments/dev/global/bootstrap/) | IAM chicken-and-egg solution, OIDC provider provisioning |
| [AI context documents](docs/context/) | Structured context docs (AWS, Terraform, K8s, security, CI/CD) following Anthropic Claude Code guidelines; patterns, anti-patterns, and governance rules per domain |
| [CLAUDE.md](CLAUDE.md) | Project-level AI assistant rulebook — hard constraints, repo navigation, methodology, and domain context pointers |
| [Lessons learned](docs/lessons-learned/) | Debugging post-mortems: private EKS networking, Fargate SG architecture, Terraform/K8s coupling |