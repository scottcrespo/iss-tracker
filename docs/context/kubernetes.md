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
| `argocd` | Private subnets | Yes — required for Git access |

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
- All images launched by a chart must be declared explicitly in `values.yaml`
  regardless of whether the component is enabled:
  - **Enabled components** — image tag must include a resolved SHA256 digest
    in `tag: "<version>@sha256:<digest>"` format. Kubernetes enforces the digest;
    the tag is retained for human readability only.
  - **Disabled components** — image tag must use the placeholder
    `"<version>@sha256:REPLACE_WITH_DIGEST"`. This is intentional soft policy
    enforcement: if an operator enables the component without resolving the digest,
    the deploy will fail, prompting them to pin before shipping.
  - Resolve digests with:
    `docker pull <image>:<tag> && docker inspect --format='{{index .RepoDigests 0}}' <image>:<tag>`
- Sensitive Helm parameters are never stored in `values.yaml` or committed to Git
- Chart structure follows the standard `helm create` scaffold; deviations are
  documented in the chart's `README.md`

**Explicit values for security-relevant and scheduling-relevant settings.**
Third-party charts (ArgoCD, ESO, LB controller) must have the following categories
set explicitly in `values.yaml`, even when accepting chart defaults. The goal is
visibility — hardening is a value edit, not a structural change:

1. **Pod identity and token handling** — `serviceAccount.create`, `name`,
   `annotations`, `automountServiceAccountToken` per component. Prevents implicit
   SA creation and documents token mount decisions.

2. **Security context** — both pod-level (`securityContext`: `runAsNonRoot`,
   `runAsUser`, `runAsGroup`, `fsGroup`, `seccompProfile`) and container-level
   (`containerSecurityContext`: `readOnlyRootFilesystem`, `allowPrivilegeEscalation`,
   `capabilities.drop`, `runAsNonRoot`, `seccompProfile`). Set globally where the
   chart supports it; override per component where needed.

3. **Scheduling** — `nodeSelector`, `tolerations`, `affinity`,
   `topologySpreadConstraints`, `priorityClassName` per component. On Fargate
   these have no effect, but explicit empty values document the decision and keep
   the structure in place for mixed-mode clusters.

4. **Networking and ingress** — `service.type`, `ingress.enabled`, `networkPolicy`
   (scaffolded disabled where not yet hardened). No service should be implicitly
   exposed. `networkPolicy.create: false` is acceptable during functional baseline;
   flip to `true` during secure baseline iteration.

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