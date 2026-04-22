# Kubernetes Context — ISS Tracker

Patterns, anti-patterns, and known gotchas for Kubernetes usage in this project.

**Update this document when:**
- ArgoCD goes live — replace helmwrap.sh references with ArgoCD Application patterns; update deploy workflow
- A new namespace is added — update the subnet tier table and document its SG/profile requirements
- Container security hardening is complete — move secure baseline items from planned to current
- A new Fargate-specific constraint or gotcha is discovered

---

## Cluster Architecture

**Fargate-only.** No managed node groups or self-managed nodes. All pods run on
AWS-managed Fargate infrastructure. This eliminates node OS patching but imposes
constraints documented below.

**Subnet tiers and namespace pinning:**

| Namespace | Fargate profile subnet | Internet egress |
|-----------|----------------------|-----------------|
| `kube-system` | Intra subnets | None — VPC endpoints only |
| `iss-tracker` | Private subnets | Yes — via NAT gateway |
| `argocd` (planned) | Private subnets | Yes — required for Git access |

Each Fargate profile explicitly pins `subnet_ids` to its tier. Without explicit
pinning, EKS schedules pods across all cluster subnets, mixing tiers.

**Security group architecture.** Fargate assigns the cluster SG to all pods by
default — a single shared SG that allows all intra-member traffic. This project
replaces the default with per-namespace SGs via `SecurityGroupPolicy` (VPC CNI
feature) to enforce least-privilege network isolation.

On Fargate, a `SecurityGroupPolicy`-assigned SG **replaces** (not augments) the
node SG. The assigned SG must include all rules the pod needs, including DNS.

Two-part requirement for every new namespace with distinct network needs:
1. New `aws_security_group` resource in the EKS terraform root
2. New `SecurityGroupPolicy` manifest applied to the cluster

---

## Helm Conventions

- Use `helmwrap.sh` — never call `helm` directly. The wrapper injects sensitive
  values (ECR repo URL, IRSA role ARN) that must not be stored in `values.yaml`
- `image.digest` (SHA256) is the preferred image reference over `image.tag` —
  digest references are immutable
- Sensitive Helm parameters are never stored in `values.yaml` or committed to Git
- Chart structure follows the standard `helm create` scaffold; deviations are
  documented in the chart's `README.md`

---

## Patterns

- `SecurityGroupPolicy` manifests live in `k8s/iss-tracker/manifests/` and are
  applied as part of the cluster bootstrap sequence, not as application manifests
- Liveness probes target a dedicated `/health` endpoint with no external dependencies
- Readiness probes target an endpoint that exercises the real dependency path
  (e.g., `/positions` for the API, which reads from DynamoDB)
- Resource `requests` and `limits` are always set — no unbounded containers
- IRSA annotations on service accounts are injected at deploy time, never hardcoded
  in `values.yaml`

---

## Anti-patterns

- **Never deploy to a namespace without a Fargate profile.** Pods will remain
  `Pending` indefinitely with no clear error message
- **Never use the node SG for pod-level rules.** On Fargate, the node SG is not
  attached to pod ENIs. Rules on the node SG have no effect on Fargate pods
- **Never add DNS rules to the node SG.** DNS rules must target the cluster SG
  (`module.eks.cluster_security_group_id`) sourced from the pod's assigned SG
- **Never rely on `imagePullPolicy: Always` as a substitute for digest pinning.**
  Use SHA256 digest references for reproducible, immutable deployments
- **Never call `helm install/upgrade` directly** — always use `helmwrap.sh`

---

## Known Gotchas

**CoreDNS uses the cluster SG, not the node SG.** The cluster SG only allows
traffic from itself by default. Any pod assigned a different SG (via
`SecurityGroupPolicy`) must have explicit UDP/TCP 53 ingress rules added to the
cluster SG, sourced from the pod's SG. See `docs/lessons-learned/private-eks-fargate-debugging.md`.

**Fargate bootstrap ordering.** A Fargate profile must exist in AWS before pods
can schedule in a namespace. This forces a `terraform apply` as a prerequisite
for any new namespace — including cluster addons like ArgoCD. A GitOps tool
cannot fully bootstrap itself on Fargate from cold start.

**ALB controller requires subnet tags for auto-discovery.** Public subnets must
be tagged `kubernetes.io/role/elb: 1` for internet-facing ALBs. Without these
tags, the controller builds an empty model and creates no ALB — with no error
event on the ingress.

**ALB controller requires multiple VPC endpoints.** The controller runs in intra
subnets with no internet route. Required endpoints: `elasticloadbalancing` and
`ec2`. Missing endpoints surface as `i/o timeout` in controller logs, one at a
time. After adding an endpoint, restart the controller deployment to clear cached
connection state.

**`SecurityGroupPolicy` selector scope.** An empty `podSelector` matches all
pods in the namespace. Verify the selector is intentionally broad before applying
— a misconfigured SGP can silently break DNS for all pods in the namespace.