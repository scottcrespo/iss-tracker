# api

Helm chart for the ISS Tracker API — a FastAPI service that exposes ISS position data stored in DynamoDB.

## Overview

- **Namespace:** `iss-tracker`
- **Image:** `<account>.dkr.ecr.us-east-2.amazonaws.com/iss-tracker-api:<git-sha>`
- **DynamoDB table:** `iss-tracker-positions`
- **AWS auth:** IRSA — the pod assumes `iss-tracker-eks-api` via a Kubernetes service account annotation
- **Ingress:** AWS ALB (internet-facing, HTTP port 80)

### Endpoints

| Path | Description |
|------|-------------|
| `GET /health` | Liveness check — returns `{"status": "ok"}` with no dependencies |
| `GET /position` | Most recent ISS position |
| `GET /positions` | Recent ISS positions, newest first. Accepts `?limit=N` (max 100) |

## Deploying

Use `helmwrap.sh` rather than calling `helm` directly. The script injects values that must not be stored in the repository — specifically the ECR registry URL (derived from the AWS account ID) and the IRSA role ARN.

```bash
cd k8s/iss-tracker/helm/api

# Install
./helmwrap.sh install

# Upgrade an existing release (e.g. after updating image.digest in values.yaml)
./helmwrap.sh upgrade

# Uninstall
./helmwrap.sh uninstall
```

The script:
1. Resolves the AWS account ID via `aws sts get-caller-identity`
2. Looks up the IRSA role ARN via `aws iam get-role`
3. Passes both as `--set` overrides at install/upgrade time so they never appear in `values.yaml` or version control

## Configuration

Sensitive values are injected at deploy time. Everything else is in `values.yaml`.

| Key | Source | Notes |
|-----|--------|-------|
| `image.repository` | `helmwrap.sh` | Derived from AWS account ID and region |
| `image.digest` | `values.yaml` | SHA256 digest of the pushed image |
| `serviceAccount.annotations` (IRSA role ARN) | `helmwrap.sh` | Looked up from IAM at deploy time |

## Security TODOs (future iterations)

- [ ] **Pod security context** - set `runAsNonRoot: true`, `runAsUser`, `runAsGroup`, `fsGroup`
- [ ] **Container security context** - `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, drop all capabilities
- [ ] **seccompProfile** - explicitly set `RuntimeDefault` (Fargate defaults to it but should be declarative)
- [ ] **NetworkPolicy** - restrict egress to DynamoDB VPC endpoint only; restrict ingress to ALB security group only; requires VPC CNI network policy addon enabled in EKS
- [ ] **RBAC** - confirm service account has no unnecessary cluster permissions beyond IRSA token exchange
- [ ] **HTTPS** - add ACM certificate and HTTPS listener to the ALB; redirect HTTP to HTTPS