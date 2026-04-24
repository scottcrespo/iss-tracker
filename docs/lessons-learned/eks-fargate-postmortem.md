# EKS + Fargate: A Detailed Postmortem

**Project:** ISS Tracker — a portfolio project intentionally built on EKS Fargate
to document its operational realities in a public, searchable codebase.

**Verdict:** EKS Fargate introduces more operational complexity than it removes.
For the vast majority of production use cases, managed node groups with Karpenter
are a strictly better choice. This document explains why, in detail, with specific
examples from a real deployment.

---

## What AWS Promises

AWS markets Fargate as "serverless compute for containers" — you define pods, AWS
runs them, you never touch a node. No AMI patching, no kubelet upgrades, no
capacity planning. It sounds like the logical endpoint of managed Kubernetes.

It is not.

---

## Problem 1: Pre-DNAT Security Group Evaluation

This is the most dangerous footgun in the Fargate networking model, and AWS
documents it poorly.

### Background

On a standard EKS cluster with EC2 nodes, security groups are attached to the
**node ENI**. All pods on a node share the node's SG. When a pod connects to a
Kubernetes Service (ClusterIP), iptables rewrites the destination from the
ClusterIP to a pod IP **inside the node kernel**, before the packet reaches the
node ENI. The SG evaluates the packet with the real pod IP as the destination.
Self-referencing SG rules (allow traffic from/to same SG) work cleanly.

On Fargate with `SecurityGroupPolicy` (VPC CNI's per-pod SG feature), each pod
gets its own **branch ENI** at the hypervisor level — outside the pod's network
namespace. The SG is evaluated at the hypervisor, **before iptables DNAT has
rewritten the ClusterIP to a pod IP**.

This means:

- Pod A wants to connect to Service B on `172.20.x.x:6379` (a ClusterIP)
- The packet leaves pod A's network namespace with destination `172.20.x.x:6379`
- The branch ENI SG evaluates: does pod A have egress permission to `172.20.x.x:6379`?
- Your self-referencing SG rule (egress to pods in the same SG) does **not** match,
  because `172.20.x.x` is a ClusterIP, not a pod IP with an SG
- The traffic is **silently dropped**

The symptoms are indistinguishable from an application bug. The pod starts,
logs look normal, and then health checks start timing out. You spend hours
suspecting application configuration before realizing the packet never left
the ENI.

### What you have to do instead

You must add explicit egress rules for the entire Kubernetes service CIDR
(`172.20.0.0/16` or whatever your cluster uses) covering every port your pods
use to talk to ClusterIP services. For a multi-component application like ArgoCD
this means all ports, all protocols — effectively:

```hcl
resource "aws_security_group_rule" "egress_service_cidr" {
  description       = "Egress to cluster service CIDR for ClusterIP traffic (pre-DNAT Fargate SG evaluation)"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.my_namespace.id
  cidr_blocks       = ["172.20.0.0/16"]
}
```

You also need separate explicit egress rules for DNS because CoreDNS is reached
via its service ClusterIP (`172.20.0.10:53`):

```hcl
resource "aws_security_group_rule" "egress_dns_udp" {
  cidr_blocks = [local.vpc_cidr, "172.20.0.0/16"]
  from_port   = 53
  to_port     = 53
  protocol    = "udp"
  ...
}
```

This is not documented prominently by AWS. It is discovered by debugging
connection timeouts at 3am.

### Why this is especially bad

The mental model breaks down completely. The entire point of a self-referencing
SG rule is "pods in this group can talk to each other." On EC2 nodes that's true.
On Fargate it's only true for **direct pod-to-pod traffic on pod IPs** — which is
not how Kubernetes applications communicate. Applications use Service DNS names,
which resolve to ClusterIPs, which the SG evaluates before DNAT. The abstraction
that Kubernetes provides (stable service addresses via ClusterIPs) actively fights
the Fargate SG model.

---

## Problem 2: SecurityGroupPolicy Replaces, Not Augments

On Fargate, a `SecurityGroupPolicy`-assigned SG **replaces** the cluster SG on
the pod's branch ENI. It does not add to it.

The cluster SG is the default SG that EKS uses for control plane communication —
API server, CoreDNS, etc. When you assign a custom SG via SGP, your pod loses all
the rules the cluster SG provided. You must replicate every rule your pod needs:

- Ingress from the cluster SG (for kubectl exec, port-forward, webhook calls)
- Egress for DNS to CoreDNS (explicitly, to the service CIDR)
- Egress for the Kubernetes API (port 443 to the cluster SG)
- All application-specific rules

If you forget any of these, pods fail silently. There is no warning that you are
operating without a rule that the cluster SG previously provided.

Compare to EC2 nodes: you add rules to the node SG or use additional SGs layered
on top. You cannot accidentally remove cluster control plane access.

---

## Problem 3: Terraform Must Own Kubernetes Topology Decisions

Fargate requires a **Fargate profile** for each namespace before pods can schedule
there. Fargate profiles are AWS resources, provisioned via Terraform (or the AWS
API). This couples your infrastructure layer to your Kubernetes namespace structure
in ways that undermine GitOps.

Consequences:

- **Adding a namespace requires a `terraform apply` before the namespace exists.**
  A GitOps tool (ArgoCD, Flux) cannot create a namespace and have pods schedule
  there without a human first running Terraform. GitOps self-healing does not work
  for new namespaces.
- **ArgoCD cannot bootstrap itself on Fargate from cold start.** ArgoCD needs to
  run in its own namespace. That namespace needs a Fargate profile. The Fargate
  profile must exist before ArgoCD pods can schedule. ArgoCD cannot provision its
  own Fargate profile. You must manually create the profile and bootstrap ArgoCD
  before ArgoCD can manage anything.
- **Per-namespace SGs become Terraform's responsibility.** The least-privilege
  network model (one SG per namespace, assigned via SGP) means Terraform owns
  your namespace network topology. Every new namespace is a Terraform resource.
  This is not separation of concerns — it is coupling infrastructure and
  application concerns at exactly the wrong layer.

On EC2 nodes, a namespace is a Kubernetes concept. You can create namespaces,
deploy pods, and manage network policy entirely within Kubernetes. GitOps works
as designed.

---

## Problem 4: No DaemonSets

Fargate does not support DaemonSets. This rules out a large portion of the
Kubernetes ecosystem:

| Tool | Deployment model | Fargate support |
|------|-----------------|-----------------|
| Datadog Agent | DaemonSet | No |
| Falco | DaemonSet | No |
| Fluent Bit (node-level) | DaemonSet | No |
| AWS Node Termination Handler | DaemonSet | No |
| Cilium | DaemonSet | No |
| Calico (node agent) | DaemonSet | No |
| Prometheus Node Exporter | DaemonSet | No |

AWS provides a Fargate-specific logging mechanism via a ConfigMap
(`aws-logging`), but it is limited compared to a proper log pipeline. If you
want Datadog, you are deploying a sidecar in every pod — a maintenance burden
that scales with pod count and contaminates your application manifests with
infrastructure concerns.

Security tooling is particularly affected. Runtime security scanners (Falco,
Aqua, Sysdig) require kernel-level access via DaemonSets. On Fargate you are
flying blind at the runtime layer.

---

## Problem 5: No Node-Level Debugging

On EC2 nodes you can SSH into a node (or use SSM), run `crictl`, inspect the
container runtime, check iptables rules, run `tcpdump` on the node interface,
and examine kubelet logs. These tools are essential for debugging networking and
scheduling problems.

On Fargate, there is no node to access. When something goes wrong at the
infrastructure level, your only visibility is:

- Pod logs (if the pod is running far enough to produce logs)
- Kubernetes events
- VPC Flow Logs (if enabled — they show ACCEPT/REJECT but not application content)
- CloudWatch Container Insights (limited, and requires the logging ConfigMap)

In practice this means debugging the pre-DNAT SG issue described above involved:
1. Pod logs showing connection timeouts with no other context
2. VPC Flow Logs showing REJECT entries for the service CIDR
3. Hours of trial and error adjusting SG rules
4. No ability to run `tcpdump` or `strace` to confirm the actual failure point

---

## Problem 6: Three Security Groups, None of Them Obviously Correct

EKS on Fargate involves three overlapping security groups that serve different
purposes, are named confusingly, and are never clearly documented together.

| SG | Source | Used by |
|----|--------|---------|
| EKS-managed primary SG (`eks-cluster-sg-*`) | `aws eks describe-cluster ... .vpc_config.cluster_security_group_id` | Fargate pods with **no** SGP — including CoreDNS |
| terraform-aws-modules cluster SG | `module.eks.cluster_security_group_id` | EKS control plane ENIs; bastion API access rules |
| Per-namespace custom SG | `aws_security_group.<ns>` | Pods assigned via SecurityGroupPolicy |

The critical trap: **DNS ingress rules must target the EKS-managed primary SG**,
not the terraform module SG. CoreDNS pods in `kube-system` have no
`SecurityGroupPolicy` and therefore use the EKS-managed primary SG. Rules on
`module.eks.cluster_security_group_id` never reach CoreDNS.

In terraform, the EKS-managed primary SG is not exposed as a module output.
You must read it back via a data source:

```hcl
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

locals {
  eks_primary_sg_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
```

Then add DNS (UDP/TCP 53) and API (TCP 443) ingress rules to
`local.eks_primary_sg_id` for every private subnet CIDR.

**Debugging anti-pattern:** you add DNS ingress rules to
`module.eks.cluster_security_group_id`, pods still can't resolve DNS, you
conclude the rules are wrong. The rules are correct — they're just on the
wrong SG. Verify which SG is actually on CoreDNS's ENI:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=private-ip-address,Values=<coredns-pod-ip>" \
  --query 'NetworkInterfaces[*].Groups'
```

Additionally, `aws_security_group_rule` with a list in `cidr_blocks` creates
multiple AWS rules but one Terraform resource. When the resource is removed from
state and re-applied, Terraform cannot reconcile the multi-rule AWS reality with
its single-resource model, producing `InvalidPermission.Duplicate` errors that
are difficult to resolve without manual state manipulation.

The correct pattern — one resource per CIDR via `for_each` — is not the obvious
pattern and is not documented prominently.

Additionally, `aws_security_group_rule` with a list in `cidr_blocks` creates
multiple AWS rules but one Terraform resource. When the resource is removed from
state and re-applied, Terraform cannot reconcile the multi-rule AWS reality with
its single-resource model, producing `InvalidPermission.Duplicate` errors that
are difficult to resolve without manual state manipulation.

The correct pattern — one resource per CIDR via `for_each` — is not the obvious
pattern and is not documented prominently.

---

## Problem 7: Cold Start Latency

Fargate cold start (from pod scheduled to pod running) is significantly slower
than EC2 nodes with pre-provisioned capacity. AWS must provision underlying
compute for each pod. In practice:

- EC2 node with capacity: pod running in ~5-10 seconds
- Fargate: pod running in 30-90 seconds, sometimes longer

For any workload that scales to zero and back (event-driven, scheduled jobs,
CI runners), this latency is a meaningful degradation in user experience or
pipeline throughput.

---

## Problem 8: Cost

Fargate pricing is per vCPU and GB of memory, billed at the pod level. EC2 node
pricing is per instance, regardless of how many pods run on it.

For a moderately loaded cluster running several pods with leftover node capacity,
EC2 managed nodes are substantially cheaper. The cost advantage of Fargate only
materializes for highly variable, spiky workloads where you would otherwise
overprovision nodes for peak capacity — and even then, Karpenter on EC2 achieves
similar bin-packing efficiency at lower per-unit cost.

A rough comparison for this project's ArgoCD + app workload: the same pods on
t3.medium managed nodes would cost a fraction of the equivalent Fargate allocation.

---

## The Alternative: Managed Node Groups + Karpenter

Everything Fargate promises, Karpenter delivers without the constraints:

| Concern | Fargate | Karpenter on EC2 |
|---------|---------|-----------------|
| Node provisioning | Automatic | Automatic |
| Node OS patching | AWS managed | AWS managed (EKS optimized AMI) |
| DaemonSets | Not supported | Fully supported |
| Node debugging | Not possible | SSH / SSM available |
| Cold start | 30-90s | 60-120s for new node, ~5s if node exists |
| SG model | Pre-DNAT, per-pod complexity | Standard, intuitive |
| GitOps compatibility | Requires Terraform for namespaces | Namespaces are pure Kubernetes |
| Cost | Premium | EC2 on-demand or Spot |
| Fargate profile coupling | Required per namespace | Not applicable |

Karpenter watches for unschedulable pods and provisions appropriately-sized EC2
instances within seconds. When pods scale down, Karpenter terminates underutilized
nodes. You get the bin-packing and scale-to-zero benefits of Fargate with none of
the networking constraints.

For runtime security, you get DaemonSet support — meaning Falco, Datadog, and the
rest of the ecosystem work as designed.

---

## When Fargate Is Appropriate

To be fair: Fargate has legitimate use cases.

- **Batch jobs and one-off tasks** where you want zero standing infrastructure and
  cold start latency is acceptable
- **Simple, single-namespace workloads** where the SG complexity doesn't compound
- **Organizations with strict node access policies** where removing SSH access to
  nodes is a compliance requirement
- **Cost-optimized dev environments** where a cluster runs a handful of small pods
  and EC2 node minimum size is wasteful

For a production multi-component application with observability, security tooling,
and GitOps requirements, Fargate is the wrong tool.

---

## Conclusion

EKS Fargate shifts operational burden rather than eliminating it. Node OS patching
disappears; pre-DNAT SG reasoning, Terraform-Kubernetes coupling, DaemonSet
incompatibility, and limited observability appear in its place. The tradeoff is
not obviously favorable for most production workloads.

This project documented these constraints in detail precisely because the AWS
documentation does not. If you found this via a search engine while debugging
a Fargate networking problem at 2am: you are not alone, it is not your fault,
and the better path forward is managed node groups with Karpenter.