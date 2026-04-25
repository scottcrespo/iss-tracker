# EKS Cluster Provisioning Runbook

**Update this runbook when:**
- A provisioning step is added, removed, or reordered
- A helm chart version is bumped (verify flag names and rollout commands remain valid)
- A Secrets Manager key name or structure changes
- A bootstrap script path or behavior changes
- A new known failure mode is discovered during an actual provisioning run
- The bastion user data installs or removes a tool that affects step prerequisites
- The target end state changes (new workload, new namespace, new ALB endpoint)

---

Step-by-step procedure to bring the cluster from zero to a fully operational
state with ArgoCD syncing the api and poller workloads. Run this after a fresh
`terraform destroy` or on a brand new environment.

## Prerequisites

The following must be in place before starting. They are not covered here.

- **Bootstrap** — IAM roles, OIDC provider, S3 state backend (`terraform/environments/dev/global/bootstrap`)
- **DynamoDB** — ISS tracker table (`terraform/environments/dev/us-east-2/dynamodb`)
- **ECR** — api and poller repositories built and pushed (`terraform/environments/dev/us-east-2/ecr`)

All kubectl and helm commands must be run **on the bastion** — the EKS API
server has no public endpoint.

---

## Step 1 — Terraform apply (EKS root)

Run locally.

```bash
cd terraform/environments/dev/us-east-2/eks
terraform plan
terraform apply
```

Provisions: VPC, subnets, NACLs, EKS cluster, Fargate profiles, IAM/IRSA roles,
and VPC endpoints.

---

## Step 2 — Terraform apply (bastion root)

The bastion is a dedicated root that pulls VPC and cluster identifiers from the
EKS root's remote state. Apply it after the EKS root is complete.

```bash
cd terraform/environments/dev/us-east-2/bastion
terraform plan
terraform apply
```

Provisions: bastion EC2 instance and EC2 Instance Connect Endpoint. User data
installs kubectl, helm, the ArgoCD CLI, clones the repo, runs
`aws eks update-kubeconfig`, and adds the `eks` helm repo — no manual tooling
setup is required after connecting.

---

## Step 3 — Connect to bastion

Run locally. The bastion has no public IP — EICE proxies the SSH connection to
its private IP.

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=iss-tracker-eks-bastion" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region us-east-2)

aws ec2-instance-connect ssh \
  --instance-id "${INSTANCE_ID}" \
  --region us-east-2 \
  --connection-type eice
```

Verify the bastion is ready — user data runs asynchronously and may still be
in progress on first boot:

```bash
# kubectl context and helm eks repo are configured by user_data; confirm both
kubectl get nodes        # "No resources found" is correct — Fargate has no visible nodes
helm repo list | grep eks
```

If either command fails, user data is still running. Check progress:

```bash
sudo journalctl -u cloud-final -f
```

---

## Step 4 — Wait for CoreDNS

CoreDNS must be ready before any helm installs. Its pods schedule in intra
subnets and depend on ECR image pull via VPC endpoints — allow 3-5 minutes
after the cluster is first created.

```bash
kubectl wait --for=condition=ready pod \
  -n kube-system -l k8s-app=kube-dns \
  --timeout=300s
```

---

## Step 5 — Install AWS Load Balancer Controller

```bash
cd k8s/kube-system/helm/aws-load-balancer-controller
./install.sh
```

Verify the controller is running before continuing — it must be ready before
any Ingress resources are created:

```bash
kubectl rollout status deployment aws-load-balancer-controller -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Step 6 — Apply iss-tracker bootstrap manifests

Creates the `iss-tracker` namespace and applies the `SecurityGroupPolicy` that
assigns the least-privilege Fargate SG to iss-tracker pods. Must be done before
any iss-tracker pods are scheduled.

```bash
cd k8s/iss-tracker/manifests/bootstrap
./bootstrap-install.sh
```

Verify:

```bash
kubectl get namespace iss-tracker
kubectl get securitygrouppolicy -n iss-tracker
```

---

## Step 7 — Apply argocd bootstrap manifests

Creates the `argocd` namespace and applies the ArgoCD `SecurityGroupPolicy`.
The namespace must exist before helm charts or ESO are installed into it.

```bash
cd k8s/argocd/manifests/bootstrap
./bootstrap-install.sh
```

Verify:

```bash
kubectl get namespace argocd
kubectl get securitygrouppolicy -n argocd
```

---

## Step 8 — Create Secrets Manager entries

These entries must exist before ESO can sync them into the cluster. Run on the
bastion (AWS CLI is configured there) or locally.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

# API helm values — ECR repo URL and IRSA role ARN
aws secretsmanager create-secret \
  --name iss-tracker/helm/api \
  --region us-east-2 \
  --secret-string "{
    \"imageRepository\": \"${ECR_BASE}/iss-tracker-api\",
    \"irsaRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/iss-tracker-eks-api\"
  }"

# Poller helm values — ECR repo URL and IRSA role ARN
aws secretsmanager create-secret \
  --name iss-tracker/helm/poller \
  --region us-east-2 \
  --secret-string "{
    \"imageRepository\": \"${ECR_BASE}/iss-tracker-poller\",
    \"irsaRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/iss-tracker-eks-poller\"
  }"
```

If re-provisioning an environment where these secrets already exist, use
`update-secret` instead of `create-secret`.

---

## Step 9 — Install ArgoCD

```bash
cd k8s/argocd/helm/argocd
./helmwrap.sh install
```

Wait for ArgoCD to be fully ready before proceeding:

```bash
kubectl rollout status deployment argocd-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd
```

Retrieve the initial admin password (save this):

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## Step 10 — Install External Secrets Operator

ESO runs in the `argocd` namespace (same namespace as ArgoCD to share the
IRSA service account that has Secrets Manager access).

```bash
cd k8s/argocd/helm/external-secrets
./helmwrap.sh install
```

Verify the ESO controller is running:

```bash
kubectl rollout status deployment external-secrets -n argocd
```

---

## Step 11 — Apply ClusterSecretStore and ExternalSecrets

The `ClusterSecretStore` points ESO at AWS Secrets Manager using the `external-secrets`
service account (IRSA). The `ExternalSecret` resources instruct ESO which Secrets
Manager keys to sync into which K8s secrets.

```bash
cd k8s/argocd/manifests
kubectl apply -f cluster-secret-store.yaml
kubectl apply -f external-secret-api.yaml
kubectl apply -f external-secret-poller.yaml
```

---

## Step 12 — Wait for ESO to sync

ESO syncs on initial apply and then on a 1-hour refresh interval. Verify both
K8s secrets exist and are populated before running deploy.sh — deploy.sh reads
directly from these secrets and will fail with an empty value if they have not
yet synced.

```bash
kubectl get externalsecret -n argocd

# Both should show READY=True and STATUS=SecretSynced
kubectl get secret api-helm-values -n argocd -o jsonpath='{.data.imageRepository}' | base64 -d && echo
kubectl get secret poller-helm-values -n argocd -o jsonpath='{.data.imageRepository}' | base64 -d && echo
```

If a secret is not synced, check ESO logs for Secrets Manager access errors:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=external-secrets --tail=50
```

---

## Step 13 — Apply ArgoCD Application manifests

With secrets synced, apply the Application manifests. This registers the api
and poller with ArgoCD and triggers the first automated sync.

```bash
cd k8s/argocd/apps
./deploy.sh apply api
./deploy.sh apply poller
```

---

## Step 14 — Verify end-to-end

```bash
# ArgoCD Applications should reach Synced/Healthy
kubectl get applications -n argocd

# Pods should be running in iss-tracker namespace
kubectl get pods -n iss-tracker -o wide

# ALB should be provisioned (may take 2-3 minutes after first sync)
kubectl get ingress -n iss-tracker

# Once ALB DNS is available, test the API
ALB_DNS=$(kubectl get ingress -n iss-tracker \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
curl "http://${ALB_DNS}/positions"
```

---

## Ordering rationale

The sequence above deviates from the intuitive order in two places worth calling out:

**Why iss-tracker and argocd bootstrap (steps 5-6) before ArgoCD helm install (step 8):**
The bootstrap scripts create the namespaces. The ArgoCD helm chart installs into
`argocd` namespace and ESO also runs in `argocd` — the namespace must pre-exist.
Creating it via the bootstrap script also applies the `SecurityGroupPolicy` in
the same operation so the SGP is in place before any pod is scheduled.

**Why ESO before deploy.sh, even though ESO is not required for ArgoCD to run:**
`deploy.sh` reads `api-helm-values` and `poller-helm-values` K8s secrets at
execution time and injects them into the Application spec. If those secrets do
not exist when deploy.sh runs, the Application is created with empty image
repository and IRSA ARN values, causing ArgoCD to fail on first sync. ESO must
have completed its initial sync before deploy.sh is invoked.