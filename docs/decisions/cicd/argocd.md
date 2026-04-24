# ArgoCD — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

This is a running document. ArgoCD is being implemented in phases per `plans/argocd.md` (gitignored); decisions below are recorded as they are made.

## ArgoCD pulls from Git rather than CI pushing to the cluster

The fundamental decision that makes GitOps compatible with this project's hard constraint of **no GitHub Actions cluster access**. ArgoCD runs inside the cluster and polls the Git repository on its own schedule. GitHub Actions never receives cluster credentials, AWS OIDC trust, or kubeconfig access. The trust direction is inverted compared to a push-based CI deploy: the cluster reaches out to Git, not the other way around.

This is the same rationale that drives the "no AWS credentials in CI" decision documented in `cicd.md` — public repository workflow logs cannot reliably suppress sensitive output, so the cluster must be the active party.

## External Secrets Operator for sensitive Helm values

Helm values that cannot be committed to Git (ECR repository URL, IRSA role ARNs) are stored in AWS Secrets Manager and surfaced into the cluster as native Kubernetes secrets by External Secrets Operator (ESO). ArgoCD-managed Helm releases reference those K8s secrets at render time.

Alternatives considered:

- **`helmwrap.sh`-style injection at deploy time** — works for manual deploys but breaks GitOps because ArgoCD has no equivalent of an out-of-band script. Sensitive values would either need to be in Git or fetched at sync time, which is exactly what ESO does — done properly.
- **Sealed Secrets** — encrypted secrets committed to Git. Rejected because the sensitive values include AWS account IDs that we explicitly do not want in the repo at all, even encrypted. Encryption protects content but does not address the principle.
- **ArgoCD Vault Plugin** — viable but adds an ArgoCD-specific dependency. ESO is a more general-purpose pattern that any controller in the cluster can use, not just ArgoCD.

ESO is a Kubernetes controller (not an application workload) and lives in `iam-controllers.tf` alongside the LB controller, with IRSA scoped to `secretsmanager:GetSecretValue` on the `iss-tracker/*` secret path only.

## ArgoCD does not manage its own Helm release

Manual `helm install` remains the bootstrap mechanism for ArgoCD itself. ArgoCD self-management adds complexity (resource ordering, sync-wave configuration, recovery-from-broken-state risk) for limited benefit on a single-cluster project. The Helm install is a one-time operation and `values.yaml` for ArgoCD lives in the repo for reproducibility — but the install command is run by hand from the bastion.

This is on the "future iterations" list, not rejected outright. It would be a meaningful addition once the core GitOps loop is stable.

## Bootstrap manifests excluded from ArgoCD scope

The `iss-tracker` namespace and `SecurityGroupPolicy` manifests remain as manual `kubectl apply` operations. They are one-time static resources tightly coupled to terraform-provisioned IAM roles and security groups; bringing them under ArgoCD adds a dependency cycle (ArgoCD needs the namespace to exist before it can manage the namespace's contents) without operational benefit.

ArgoCD's scope is application workloads — `api` and `poller` — where the GitOps loop has clear value: frequent image digest updates, observable sync state, drift detection.

## No ArgoCD UI exposure

The ArgoCD server is `ClusterIP` only. The bastion is in a private subnet with no browser, and the cluster has no public ingress for ArgoCD. All operations are performed via the ArgoCD CLI, tunneled through `kubectl port-forward` to bastion localhost.

Exposing the UI publicly would require a dedicated ALB, a public DNS entry, TLS termination, and an authentication integration — significant attack surface for a single-developer project. The CLI covers every operational need (sync, diff, app status, history) and is the authoritative interface in any case. UI access is on the "future iterations" list if multi-developer collaboration ever becomes a requirement.

## ArgoCD runs in private subnets, not intra

The `argocd` namespace is pinned to the private subnet Fargate profile so ArgoCD has NAT gateway egress to reach GitHub for repository polling. This is the same pattern as the `iss-tracker` namespace (which needs NAT for the poller's outbound ISS API calls).

The `kube-system` namespace remains on intra subnets with no internet route — its workloads (CoreDNS, LB controller) only talk to AWS services via VPC endpoints. ArgoCD cannot follow that pattern because it must reach Git over the public internet.

## ESO co-located with ArgoCD in the argocd namespace

Both ArgoCD and ESO are cluster-level controllers that support GitOps delivery. Co-locating them in the same namespace keeps the controller plane logically separate from the application plane (`iss-tracker`), shares one Fargate profile, and means a single `SecurityGroupPolicy` can govern controller-pod network access if needed.

Alternative: separate `external-secrets` namespace. Rejected to avoid the additional Fargate profile, SecurityGroupPolicy, and IAM blast radius for no operational benefit at this scale.

## Image digest pinning is preserved

`image.digest` (SHA256) remains in `values.yaml` and is committed to Git. A digest is a content hash, not a secret — it identifies the exact image bytes and changes only when a new image is built and pushed. ArgoCD detects digest changes in `values.yaml` on the next sync and triggers a rolling update.

The deploy workflow becomes: developer builds image manually → pushes to ECR manually → updates `image.digest` in `values.yaml` → commits → ArgoCD auto-sync deploys. Image build/push remains manual for the same reason terraform apply does — public CI logs cannot safely emit registry URLs and account IDs.

## helmwrap.sh retired as the primary deploy mechanism

Once ArgoCD manages the `api` and `poller` Helm releases, `helmwrap.sh` is no longer the standard deploy path. It may be retained for emergency out-of-band deploys (e.g., ArgoCD itself is down and an urgent fix is needed), but the documented and expected path is `git commit` → ArgoCD sync.

## Decisions deferred

The following are explicitly out of scope for the initial implementation and tracked in `plans/argocd.md`:

- **ArgoCD RBAC scoped below cluster-admin** — initial install uses the chart's default RBAC; least-privilege scoping is a follow-up
- **Container security context for ArgoCD/ESO** — `runAsNonRoot`, `readOnlyRootFilesystem`, capability drops apply uniformly across ArgoCD, ESO, and app pods in the secure-baseline phase
- **NetworkPolicy** — restricting ArgoCD egress to Git + K8s API only is part of the secure baseline
- **App-of-Apps pattern** — a single root Application managing all child Applications; useful at higher app counts, premature here
- **LB controller under ArgoCD management** — listed as a stretch objective; weighed against container hardening work when the core loop is complete
