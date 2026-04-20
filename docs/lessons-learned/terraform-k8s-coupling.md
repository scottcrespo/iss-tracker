# Lessons Learned: Terraform / Kubernetes Provisioning Tight Coupling

## The Problem

On a standard EKS cluster with managed node groups, Kubernetes namespaces,
service accounts, and workloads can be provisioned independently of the
underlying AWS infrastructure. Terraform creates the cluster; everything
inside it is managed separately via kubectl, Helm, or a GitOps tool.

On a **Fargate-only cluster**, this separation breaks down in two distinct ways.

---

## Coupling Point 1: Fargate Profiles

Fargate requires an explicit profile for each namespace before any pod in that
namespace can schedule. Profiles are AWS resources — they live in terraform,
not in Kubernetes. This creates a hard ordering dependency:

```
terraform apply (Fargate profile exists in AWS)
  → kubectl / Helm can schedule pods in that namespace
  → GitOps tool can manage workloads in that namespace
```

A GitOps tool like ArgoCD cannot bootstrap itself into a new namespace — the
Fargate profile for that namespace must be pre-provisioned by terraform before
ArgoCD can schedule its own pods.

This makes the EKS root terraform module a coupling point between AWS
infrastructure and Kubernetes application topology. Adding a new workload —
whether an app or a cluster addon like ArgoCD or ESO — requires a terraform
change before any Kubernetes resources can be created.

### Implications for GitOps Bootstrap

Any cluster addon requires a two-phase bootstrap on Fargate:

1. **Terraform phase** — creates the Fargate profile for the addon namespace
   and any required IAM roles (IRSA).
2. **Manual install phase** — Helm installs the addon; pods can now schedule
   because the profile exists.

Only after phase 2 can ArgoCD take over ongoing management of workloads.
This two-phase pattern is a permanent operational characteristic of this
architecture, not a temporary gap. Any new namespace added to the cluster
requires a terraform apply before workloads can run there.

---

## Coupling Point 2: Security Group Management

### Default Fargate Behavior

On a Fargate-only EKS cluster, all pods are assigned the **cluster security
group** by default. This is a single shared SG that allows all traffic between
members — it is not scoped to individual workloads or namespaces.

### Our Approach: Least-Privilege Networking

We opted out of the default shared-SG model in favor of per-namespace security
groups to enforce least-privilege network access. This requires:

1. **A dedicated SG per namespace tier defined in terraform** — each SG is
   scoped to the specific egress/ingress that namespace's workloads require.
   For example, `fargate_private` (iss-tracker) allows DynamoDB and ISS API
   egress; a future `fargate_argocd` SG would allow Git (HTTPS) egress.

2. **A `SecurityGroupPolicy` resource per namespace in Kubernetes** — this is
   a custom resource (provided by the VPC CNI plugin) that assigns a specific
   SG to pods in a given namespace, overriding the default cluster SG assignment.

This means every new namespace with distinct network access requirements
produces work in two places:
- A new `aws_security_group` resource in the terraform EKS module
- A new `SecurityGroupPolicy` manifest applied to the cluster

### Why We Accepted This Trade-off

The default shared cluster SG grants all pods in the cluster unrestricted
lateral access to each other and to any AWS service any other pod can reach.
For a security-conscious portfolio project, this is not acceptable. Scoped SGs
per namespace enforce that a compromised pod in the iss-tracker namespace
cannot reach resources intended only for kube-system workloads, and vice versa.

The operational cost — additional terraform resources and K8s manifests per
namespace — is the price of that isolation. It scales linearly with namespace
count, which is manageable at this project's scope.

### Scaling Concern

As namespace count grows (e.g., adding `argocd`, potentially `monitoring`), the
EKS module accumulates more SG definitions and the cluster accumulates more
`SecurityGroupPolicy` resources. If namespace count becomes large, this pattern
warrants revisiting — either through a standardized SG module abstraction or
by accepting a coarser-grained SG model for lower-risk namespaces.

---

## Why We Accepted Both Trade-offs

The alternative approaches carry their own costs:

- **Separate terraform module per namespace** — reduces coupling but increases
  the number of modules to coordinate and apply in order.
- **EKS managed node groups instead of Fargate** — eliminates both profile and
  SG coupling requirements but sacrifices Fargate's operational simplicity and
  security isolation (no node OS to patch, no shared node blast radius).
- **Accept the default cluster SG** — eliminates the SecurityGroupPolicy
  complexity but sacrifices least-privilege network isolation.

For a single-environment portfolio project, consolidating in the EKS root
module and accepting the coupling is the pragmatic choice. The trade-offs are
visible, documented, and manageable at this scale.

---

## Mitigations

- Document the required terraform apply as the first step in any runbook for
  adding a new workload or addon.
- Keep Fargate profiles, IRSA roles, and security group definitions grouped and
  clearly commented in the EKS module so the coupling is explicit.
- Treat `SecurityGroupPolicy` manifests as infrastructure-adjacent resources —
  apply them as part of the cluster bootstrap sequence, not as application
  manifests.
- If the project scope expands significantly, revisit splitting the EKS module
  into separate infra and k8s-config layers.
