# poller

Helm chart for the ISS Tracker poller — a CronJob that fetches the current ISS position from the public Open Notify API every 5 minutes and writes it to DynamoDB.

Built on [bambash/helm-cronjobs](https://github.com/bambash/helm-cronjobs) starter.

## Overview

- **Schedule:** `*/5 * * * *`
- **Namespace:** `iss-tracker`
- **Image:** `<account>.dkr.ecr.us-east-2.amazonaws.com/iss-tracker-poller:<git-sha>`
- **DynamoDB table:** `iss-tracker-positions`
- **AWS auth:** IRSA — the pod assumes `iss-tracker-eks-poller` via a Kubernetes service account annotation

## Deploying

Use `install.sh` rather than calling `helm install` directly. The script injects values that must not be stored in the repository — specifically the ECR registry URL (derived from the AWS account ID) and the IRSA role ARN.

```bash
cd k8s/iss-tracker/helm/poller
./install.sh
```

The script:
1. Resolves the AWS account ID via `aws sts get-caller-identity`
2. Looks up the IRSA role ARN via `aws iam get-role`
3. Passes both as `--set` overrides at install time so they never appear in `values.yaml` or version control

To upgrade an existing release:

```bash
helm upgrade poller . \
  -n iss-tracker \
  -f ./values.yaml \
  --set "jobs.iss-tracker-poller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(aws iam get-role --role-name iss-tracker-eks-poller --query Role.Arn --output text)" \
  --set "jobs.iss-tracker-poller.image.repository=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-2.amazonaws.com/iss-tracker-poller"
```

## Configuration

Sensitive values are injected at deploy time. Everything else is in `values.yaml`.

| Key | Source | Notes |
|-----|--------|-------|
| `image.repository` | `install.sh` | Derived from AWS account ID |
| `image.tag` | `values.yaml` | Git SHA digest of the pushed image |
| `serviceAccount.annotations` (IRSA role ARN) | `install.sh` | Looked up from IAM at deploy time |
| `env.DYNAMODB_TABLE` | `values.yaml` | `iss-tracker-positions` |
| `env.AWS_DEFAULT_REGION` | `values.yaml` | `us-east-2` |

## Security TODOs (future iterations)

- [ ] **Pod security context** - set `runAsNonRoot: true`, `runAsUser`, `runAsGroup`, `fsGroup`
- [ ] **Container security context** - `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, drop all capabilities
- [ ] **seccompProfile** - explicitly set `RuntimeDefault` (Fargate defaults to it but should be declarative)
- [ ] **NetworkPolicy** - restrict egress to DynamoDB VPC endpoint and ISS API only; requires VPC CNI network policy addon enabled in EKS
- [ ] **RBAC** - confirm service account has no unnecessary cluster permissions beyond IRSA token exchange
- [ ] **Service account token** - disable auto-mount of service account token if not needed (`automountServiceAccountToken: false`); IRSA injects its own projected token