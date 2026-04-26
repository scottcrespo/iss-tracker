# Container Runtime Hardening Plan

## About This Document

Implementation plans in this project are normally working documents stored in
`plans/` and gitignored. They are treated as ephemeral scaffolding: once a
feature is implemented, the lasting artifacts are the decision records in
`docs/decisions/`, the lessons learned in `docs/lessons-learned/`, and the
code itself. Plans are not committed because their value is in the planning
process, not in preserving a snapshot of pre-implementation thinking.

This plan is an exception. It has been committed to `docs/plan-examples/` to
demonstrate the planning methodology applied to a non-trivial infrastructure
security change. Specifically, it illustrates:

- **Operational maturity** — treating a security hardening task as a structured
  engineering problem with defined scope, phased delivery, and explicit
  verification gates rather than an ad-hoc checklist
- **Change management** — full impact analysis across Terraform, Dockerfiles,
  Helm charts, manifests, and documentation before a line of code is written
- **Security reasoning** — deliberate sequencing decisions grounded in how Linux
  capabilities, seccomp, and Kubernetes NetworkPolicy interact at the kernel
  level; scope decisions grounded in operational sustainability rather than
  compliance theater
- **Process discipline** — the planning standard itself is documented in
  `docs/context/runbooks.md` and `CLAUDE.md`; this plan is an example of that
  standard applied

**This document should not be read as a description of the project's current
implementation state.** Plans reflect intent at the time of writing. The
authoritative record of what is actually implemented lives in the codebase, the
`README.md` current state section, and the decision records in `docs/decisions/`.
As implementation progresses, those artifacts are updated; this plan is not.

---

## Scope

**In scope:** `api` and `poller` first-party applications only.

**Explicitly out of scope:** ArgoCD, ESO, AWS Load Balancer Controller, CoreDNS.
Third-party components maintain their own security posture upstream. Taking full
security ownership of third-party helm charts requires deep knowledge of each
chart's internals and must be re-validated on every chart upgrade. The portfolio
signal from hardening the first-party applications is equivalent without that
operational cost. This scope decision must be reflected in CLAUDE.md, README.md,
and docs/context/security.md (see Documentation Impact section).

---

## Target End State

Both `api` and `poller` pods comply with the Kubernetes Pod Security Standards
**Restricted** policy level and enforce NetworkPolicy egress/ingress rules. No
capability is granted beyond what the application requires. The runtime presents
the minimum necessary attack surface the platform allows.

---

## Complete List of Runtime Security Targets

### Dockerfile layer

| Setting | api | poller | Current state |
|---------|-----|--------|---------------|
| Non-root `USER` directive | ✅ | ✅ | `appuser` created and set |
| Deterministic UID | ❌ | ❌ | `useradd` assigns next available UID dynamically |
| `PYTHONDONTWRITEBYTECODE=1` | ❌ | ❌ | Not set — Python writes `__pycache__` at runtime, blocking `readOnlyRootFilesystem` |

### Kubernetes pod-level `securityContext`

| Setting | api | poller | Current state | Phase |
|---------|-----|--------|---------------|-------|
| `runAsNonRoot: true` | ❌ | ❌ | `podSecurityContext: {}` | 2a |
| `runAsUser: 1000` | ❌ | ❌ | Not set | 2a |
| `runAsGroup: 1000` | ❌ | ❌ | Not set | 2a |
| `fsGroup: 1000` | ❌ | ❌ | Not set | 2a |
| `seccompProfile` | — | — | **Not set at pod level — must remain unset.** See sequencing rationale. | — |

### Kubernetes container-level `securityContext`

| Setting | api | poller | Current state | Phase |
|---------|-----|--------|---------------|-------|
| `allowPrivilegeEscalation: false` | ❌ | ❌ | Not set | 2a |
| `readOnlyRootFilesystem: true` | ❌ | ❌ | Not set; requires tmpfs volume for `/tmp` | 2a |
| `capabilities.drop: ["ALL"]` | ❌ | ❌ | Not set | 2a |
| `runAsNonRoot: true` | ❌ | ❌ | Not set (PSS Restricted requires at both pod and container level) | 2a |
| `privileged: false` | ❌ | ❌ | Defaults false but not explicit | 2a |
| `seccompProfile: RuntimeDefault` | ❌ | ❌ | Not set — **container level only, Phase 2b** | 2b |

### Kubernetes ServiceAccount

| Setting | api | poller | Current state | Phase |
|---------|-----|--------|---------------|-------|
| `automountServiceAccountToken: false` | ❌ | ❌ | api: `automount: true`; poller: field absent from SA template | 2a |

Note: IRSA projected tokens are injected by the EKS pod identity webhook
independently of `automountServiceAccountToken`. AWS API access is unaffected
by setting this to false.

### RBAC

No Role or RoleBinding required. Neither `api` nor `poller` calls the Kubernetes
API. The absence of a RoleBinding is the secure state — there are no permissions
to restrict because none have been granted. `automountServiceAccountToken: false`
is the enforcement mechanism; RBAC is irrelevant when no credential is presented.

### NetworkPolicy

**Not supported on EKS Fargate.** Native Kubernetes NetworkPolicy enforcement
requires the vpc-cni eBPF agent, which needs privileged host kernel access. On
Fargate, each pod runs in its own managed microVM with no accessible host. There
is no DaemonSet path and no mutating webhook for sidecar injection. NetworkPolicy
objects are accepted by the API server and silently unenforced. Confirmed
empirically: a default-deny policy applied to the `iss-tracker` namespace had no
effect on ALB traffic. See `docs/lessons-learned/fargate-networking-deep-dive.md`.

| Setting | api | poller | Current state |
|---------|-----|--------|---------------|
| Default-deny ingress | n/a | n/a | Not achievable on Fargate |
| Default-deny egress | n/a | n/a | Not achievable on Fargate |
| Ingress TCP 8000 from VPC | n/a | n/a | Not achievable on Fargate |
| Egress UDP/TCP 53 (DNS) | n/a | n/a | Not achievable on Fargate |
| Egress TCP 443 to `0.0.0.0/0` | n/a | n/a | Not achievable on Fargate |

---

## Implementation Sequence and Rationale

Three sequenced phases with a verification gate between each. The sequencing
is deliberate — each phase isolates one variable.

### Phase 1 — NetworkPolicy enforcement

**Eliminated. NetworkPolicy enforcement is not supported on EKS Fargate.**

The original sequencing rationale placed NetworkPolicy first because a confirmed
working NetworkPolicy baseline was needed before applying `seccompProfile:
RuntimeDefault` — otherwise a broken egress rule could surface as a seccomp
violation (both produce EPERM, making root-cause analysis impossible).

This rationale is moot: NetworkPolicy cannot be enforced on Fargate regardless
of the vpc-cni configuration. The vpc-cni `enableNetworkPolicy: "true"` addon
setting uses eBPF, which requires privileged host kernel access. Fargate runs
each pod in its own managed microVM with no accessible host — there is no
DaemonSet path, no mutating webhook, and no sidecar injection mechanism. Setting
`enableNetworkPolicy: "true"` on a Fargate-only cluster results in objects being
silently unenforced. Confirmed empirically during implementation.

The Phase 2a/2b sequencing is preserved independently: capabilities and seccomp
are still applied in separate phases because they operate at different kernel
layers and both produce EPERM on failure.

### Phase 2a — securityContext (without seccomp)

Applied after Phase 1 is confirmed working. Includes: `runAsNonRoot`,
`runAsUser/Group/fsGroup`, `allowPrivilegeEscalation: false`,
`readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`, `privileged: false`,
`automountServiceAccountToken: false`.

`capabilities.drop: ["ALL"]` is applied here, before seccomp, because the two
operate at different kernel layers and produce indistinguishable failure signatures
when applied simultaneously. Capabilities are checked by the kernel after a syscall
is admitted; seccomp filters whether the syscall is admitted at all. Both can
produce EPERM. Sequencing capabilities first allows clean verification that no
required capability was dropped before seccomp introduces a second filtering layer.

`readOnlyRootFilesystem: true` requires two supporting changes:
- `ENV PYTHONDONTWRITEBYTECODE=1` in the Dockerfile — prevents Python from writing
  `__pycache__` into the source directory at runtime
- A `tmpfs` volume mounted at `/tmp` — Python and the AWS SDK use `/tmp` for
  temporary files; without a writable tmpfs the app will fail on first write

### Phase 2b — seccompProfile: RuntimeDefault (container level only)

Applied last. Applied at the **container level only** — not at pod level.

The original rationale for container-level scoping was to avoid breaking the
vpc-cni network policy agent sidecar, which requires the `bpf()` syscall absent
from RuntimeDefault. That concern is moot on Fargate — there is no sidecar.

Container-level application is still the correct approach regardless: it is more
targeted and explicit. Pod-level seccompProfile applies to all containers in the
pod including any future injected sidecars; container-level application ensures
the profile is scoped precisely to the workload container being hardened.

---

## Change Impact Analysis

### Terraform

| File | Change | Phase |
|------|--------|-------|
| `terraform/environments/dev/us-east-2/eks/eks.tf` | Add `vpc-cni` addon with `enableNetworkPolicy: "true"` | 1a |

### Dockerfiles

| File | Change | Phase |
|------|--------|-------|
| `apps/api/Dockerfile` | Fix `useradd` to deterministic UID 1000 (`--uid 1000`); add `ENV PYTHONDONTWRITEBYTECODE=1` | 2a |
| `apps/poller/Dockerfile` | Same as api | 2a |

### Helm charts

| File | Change | Phase |
|------|--------|-------|
| `k8s/iss-tracker/helm/api/values.yaml` | Fill in `podSecurityContext`, `securityContext`, `automount: false`, add tmpfs `volumes`/`volumeMounts`; add container-level `seccompProfile` | 2a/2b |
| `k8s/iss-tracker/helm/api/templates/deployment.yaml` | No template changes — scaffolding already supports all required fields | — |
| `k8s/iss-tracker/helm/api/templates/serviceaccount.yaml` | No template changes — `automountServiceAccountToken` already rendered from `serviceAccount.automount` | — |
| `k8s/iss-tracker/helm/poller/values.yaml` | Fill in `securityContext`, add tmpfs `volumes`/`volumeMounts`; add container-level `seccompProfile` | 2a/2b |
| `k8s/iss-tracker/helm/poller/templates/cronjob.yaml` | Add container-level `securityContext` block — template currently has partial pod-level support only | 2a |
| `k8s/iss-tracker/helm/poller/templates/serviceaccount.yaml` | Add `automountServiceAccountToken` field — currently absent | 2a |

### New manifests

| File | Change | Phase |
|------|--------|-------|
| `k8s/iss-tracker/manifests/network-policy/netpol-api.yaml` | NetworkPolicy for api | 1b |
| `k8s/iss-tracker/manifests/network-policy/netpol-poller.yaml` | NetworkPolicy for poller | 1b |

### Documentation

| File | Change |
|------|--------|
| `CLAUDE.md` | Current State: move hardening from "Up next" to complete; add scope note (3rd party excluded) |
| `README.md` | Move hardening from To Do to complete; add scope note to design principles |
| `docs/context/security.md` | Move "secure baseline — planned" to current baseline; document scope limitation |
| `docs/context/kubernetes.md` | Update secure baseline section to reflect implemented state |
| `docs/lessons-learned/` | Add entry: NetworkPolicy on Fargate — enforcement requirement, sidecar seccomp interaction, gateway endpoint egress behavior |

---

## Estimated Level of Effort

| Work item | LOE |
|-----------|-----|
| Phase 1a: vpc-cni Terraform change + apply + pod restart | 1 hr |
| Phase 1a: enforcement verification (smoke-test deny-all) | 1 hr |
| Phase 1b: NetworkPolicy manifests (api + poller) | 2 hr |
| Phase 1b: NetworkPolicy smoke tests | 1 hr |
| Phase 2a: Dockerfile UID + PYTHONDONTWRITEBYTECODE | 30 min |
| Phase 2a: api values.yaml security context + tmpfs | 1 hr |
| Phase 2a: poller template changes + values | 2 hr |
| Phase 2a: verification (caps, readOnly, automount) | 1 hr |
| Phase 2b: seccompProfile (container-level) + verification | 1 hr |
| Documentation | 2 hr |
| **Total** | **~13 hours / ~1.5 days** |

Primary uncertainty: whether any AWS SDK call in api or poller requires a syscall
absent from RuntimeDefault. Expected to be clean for standard Python HTTP + boto3
workloads, but must be verified empirically.

---

## Test and Verification Plan

### Phase 1a — Enforcement active

```bash
# Verify addon is active with network policy enabled
aws eks describe-addon --cluster-name iss-tracker-eks \
  --addon-name vpc-cni --region us-east-2 \
  --query 'addon.configurationValues'

# Restart pods to receive the network policy agent sidecar
kubectl rollout restart deployment -n iss-tracker

# Verify sidecar is present
kubectl describe pod -n iss-tracker -l app.kubernetes.io/name=api \
  | grep -A5 "Containers:"
# Expected: aws-network-policy-agent container listed alongside api container

# Smoke test — apply a default-deny policy and confirm traffic drops
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: smoke-test-deny-all
  namespace: iss-tracker
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
# Wait ~30s for ALB health checks to fail, then clean up
kubectl delete networkpolicy smoke-test-deny-all -n iss-tracker
```

### Phase 1b — NetworkPolicy correct

```bash
# Apply NetworkPolicy manifests
kubectl apply -f k8s/iss-tracker/manifests/network-policy/

# Verify api responds through ALB
curl "http://${ALB_DNS}/positions"
# Expected: HTTP 200 with ISS position data

# Verify poller writes succeed
kubectl logs -n iss-tracker -l cron=iss-tracker-poller --tail=20
# Expected: successful DynamoDB write entries, no connection errors

# Verify unexpected traffic is blocked — attempt a connection outside policy rules
kubectl exec -n iss-tracker deploy/api -- \
  curl -s --max-time 5 http://169.254.169.254/latest/meta-data/
# Expected: timeout (not refused — timeout proves NetworkPolicy drop, not TCP RST)
```

### Phase 2a — securityContext (no seccomp)

```bash
# Verify pods start cleanly
kubectl rollout status deployment -n iss-tracker
kubectl get pods -n iss-tracker

# Verify non-root UID
kubectl exec -n iss-tracker deploy/api -- id
# Expected: uid=1000(appuser) gid=1000(appuser)

# Verify readOnlyRootFilesystem — write to app directory must fail
kubectl exec -n iss-tracker deploy/api -- touch /app/test
# Expected: touch: cannot touch '/app/test': Read-only file system

# Verify tmpfs is writable
kubectl exec -n iss-tracker deploy/api -- touch /tmp/test && echo "tmpfs ok"
# Expected: tmpfs ok

# Verify NetworkPolicy still enforced after restart
curl "http://${ALB_DNS}/positions"
# Expected: HTTP 200
```

### Phase 2b — seccompProfile: RuntimeDefault

```bash
# Verify pods start cleanly after seccomp applied
kubectl rollout status deployment -n iss-tracker

# Confirm seccomp is scoped to container, not pod
kubectl get pod -n iss-tracker -l app.kubernetes.io/name=api -o yaml \
  | grep -A3 seccompProfile
# Expected: seccompProfile present under containers[].securityContext only,
#           absent from spec.securityContext (pod level)

# Verify no syscall violations in application logs
kubectl logs -n iss-tracker deploy/api | grep -i "operation not permitted\|seccomp\|syscall"
# Expected: no matches

# Verify NetworkPolicy agent sidecar still functional (NetworkPolicy still enforced)
kubectl exec -n iss-tracker deploy/api -- \
  curl -s --max-time 5 http://169.254.169.254/latest/meta-data/
# Expected: timeout — confirms sidecar is still enforcing policy

# Final end-to-end smoke test
curl "http://${ALB_DNS}/positions"
# Expected: HTTP 200 with ISS position data
```