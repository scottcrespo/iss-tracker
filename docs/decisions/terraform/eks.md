# EKS Cluster — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Fargate workers

Fargate is used instead of managed node groups. Workers run on AWS-managed infrastructure — there are no EC2 nodes to patch, scale, or manage.

### Tradeoffs accepted
- No DaemonSets. Node-level agents (node-exporter, Fluentd as a DaemonSet) cannot run on Fargate. Observability tooling must be adapted — see the observability decisions in `docs/decisions/k8s/k8s.md`.
- CoreDNS must be patched to run on Fargate. The EKS Terraform module handles this but it is a required configuration step.
- Slightly higher per-vCPU/memory cost than EC2 for sustained workloads. Acceptable for a demonstration project where operational simplicity and cost predictability matter more than raw cost efficiency.

### Why this is the right call for this project
The project exists to demonstrate platform engineering skills, not to operate production infrastructure at scale. Fargate eliminates node group sizing, AMI management, and cluster autoscaler configuration — all of which would add complexity without adding learning value relative to the project's goals. The tradeoffs are documented and defensible.

## VPC design

A dedicated VPC is provisioned using `terraform-aws-modules/vpc`. No default VPC resources are used.

### Subnet layout

| Subnet type | Subnets | Aggregate | Used for | Internet egress |
|-------------|---------|-----------|----------|----------------|
| Private | `10.0.0-2.0/24` | `10.0.0.0/17` | iss-tracker Fargate pods, bastion host | Yes (NAT gateway) |
| Intra | `10.0.128-130.0/24` | `10.0.128.0/18` | kube-system Fargate pods | None |
| Public | `10.0.192-194.0/24` | `10.0.192.0/18` | Load balancers only | Yes (IGW) |

The three parent blocks partition the VPC exactly: `/17 + /18 + /18 = /16` — no gaps, no overlap. The aggregate for any tier is determinable by inspection: third octet `< 128` is private, `128–191` is intra, `192+` is public. No cross-reference to subnet definitions is needed to verify tier membership of any IP.

The VPC uses three subnet tiers rather than the conventional two (public/private). The split between private and intra is deliberate: not all workloads need internet access, and conflating "internal" with "has a NAT route" gives every workload capabilities it doesn't need.

**Intra subnets** host `kube-system` pods (CoreDNS, AWS Load Balancer Controller). These workloads only communicate with AWS services via VPC endpoints — they never initiate internet connections. Placing them in subnets with no NAT route enforces that constraint at the network layer, not just at the security group layer.

**Private subnets** host `iss-tracker` pods and the bastion host. The poller must reach the public ISS position API over the internet. A NAT gateway in the public subnet provides outbound internet for private subnets without exposing them to inbound connections. A single NAT gateway is used for dev cost control; production would use one per AZ for HA.

The bastion sits in the private subnet rather than the public subnet. NAT gateway handles all outbound internet traffic (kubectl and helm downloads on first boot). No public IP is assigned — EC2 Instance Connect Endpoint proxies SSH to the bastion's private IP, so no inbound internet exposure is required. The public subnet is reserved exclusively for the ALB.

#### CIDR allocation rationale

**Private gets `/17` (half the VPC).** Application workloads live here, and on EKS Fargate each pod consumes a dedicated branch ENI with a real VPC IP. Pod density is bounded by subnet address space — a `/24` gives roughly 200 usable pod IPs after VPC-reserved addresses. A `/17` provides 128 `/24`s of reserved expansion room and — critically — remains permanently summarizable as a single CIDR regardless of how many subnets are added later. This matters: Fargate NACL debugging is significantly more complex than on EC2 (see `docs/lessons-learned/fargate-networking-deep-dive.md`), and a two-CIDR private tier would require two entries on every cross-tier NACL rule, doubling the rule count in the tier most likely to hit the AWS 20-rule NACL limit. The `/17` forecloses that problem permanently.

**Intra and public each get `/18` (one quarter each).** Intra hosts system workloads with bounded growth — CoreDNS, LB controller, VPC endpoint ENIs. Public hosts only ALB ENIs. A `/18` provides 64 `/24`s of room for each, which is more than sufficient, and the two `/18`s together account for the other half of the VPC cleanly.

#### Alternatives considered

**Original ad-hoc layout (rejected).** The initial subnet assignments used non-aligned addresses (`10.0.1-3.0/24` for private, `10.0.51-53.0/24` for intra, `10.0.101-103.0/24` for public). None of the three tiers had a clean power-of-2-aligned parent block. The intra aggregate required `/21`-alignment math (`floor(51/8)×8 = 48 → 10.0.48.0/21`) and included six unallocated `/24`s as collateral. The public subnets had no clean parent at all — they could not be aggregated. The ad-hoc layout made NACL rule auditing dependent on looking up subnet definitions, and added phantom address ranges that were harmless but increased audit surface. See `docs/lessons-learned/private-eks-fargate-debugging.md` section 10 for the full alignment derivation.

**Intra-first ordering: `intra/private/public` (considered, rejected).** An alternative with intra at `10.0.0.0/18`, private at `10.0.64.0/18`, and public at `10.0.128.0/18` was evaluated. The motivation was placing the most protected tier at the lowest numerical range. This failed on one critical constraint: the private tier would occupy a `/18` (`10.0.64.0/18`), which cannot be expanded without creating a second discontiguous block. Two separate private CIDRs — say `10.0.64.0/18` and some future `10.0.192.0/18` — cannot be summarized into a single aggregate. With private as the growth tier and Fargate's hard per-pod IP dependency, a two-CIDR private tier is a significant operational liability. The `/17` for private requires it to occupy the lower half of the VPC (base address must be a multiple of 128 for `/17` alignment), which means private starts at `10.0.0.0` and intra follows above it. The numerical ordering preference was outweighed by the aggregation constraint.

**Equal three-way split: three `/18`s (considered, rejected).** Three equal `/18`s (`10.0.0.0/18`, `10.0.64.0/18`, `10.0.128.0/18`) were also considered. This sacrifices the permanently-summarizable private tier in exchange for symmetry. Given the documented Fargate IP density constraint and the NACL complexity that follows from a multi-CIDR private aggregate, symmetry was not worth the tradeoff. Private gets more space because private has more growth pressure.

### Fargate profile subnet pinning

Without explicit `subnet_ids` on a Fargate profile, EKS schedules pods across all subnets passed to the cluster's `subnet_ids` parameter, mixing tiers. Each profile explicitly pins to its subnet tier:

```hcl
kube_system { subnet_ids = module.vpc.intra_subnets   }
iss_tracker { subnet_ids = module.vpc.private_subnets }
```

This ensures the routing and security group design is deterministic — a `kube-system` pod will never land in a private subnet and gain NAT access it shouldn't have.

### Dedicated security groups per subnet tier

#### Node security group vs pod security group

The EKS module creates one **node security group** that, by default, attaches to the ENI of every Fargate pod in the cluster — regardless of which Fargate profile placed the pod. The Fargate profile resource has no `security_group_ids` parameter; this is an AWS API constraint, not a module limitation.

Giving both `kube-system` and `iss-tracker` pods the same SG would require adding internet egress rules to the node SG, which would grant kube-system pods permissions they don't need. The intra subnet routing would prevent them from actually reaching the internet, but defense in depth is better than relying on a single routing control.

The solution is **Security Groups for Pods** (a VPC CNI feature), implemented via a `SecurityGroupPolicy` Kubernetes object. The VPC CNI controller watches for `SecurityGroupPolicy` resources and, when a pod starts, attaches the specified SG to the pod's branch ENI **instead of** the node SG. On Fargate, the SGP-assigned SG replaces rather than augments the node SG, so the assigned SG must include all rules the pod needs.

Two distinct pod security groups result:

| SG | Applied to | Egress |
|----|-----------|--------|
| Node SG (module-created) | `kube-system` pods (default, no SGP) | VPC endpoints only |
| `fargate_private` (SGP-assigned) | `iss-tracker` pods | VPC endpoints + internet via NAT |

The `SecurityGroupPolicy` manifest lives at `k8s/sgp-iss-tracker.yaml`. It targets all pods in the `iss-tracker` namespace via an empty `podSelector`. The SG ID is a Terraform output (`fargate_private_sg_id`) injected at apply time.

#### Endpoint security groups per subnet tier

Interface endpoints place ENIs in the intra subnets. Private subnet pods can reach those ENIs via VPC-local routing (no cross-subnet route entry needed; all subnets are within `10.0.0.0/16`). Two dedicated endpoint SGs — `vpc_endpoints_intra` and `vpc_endpoints_private` — scope ingress to their respective subnet CIDRs rather than the full VPC CIDR. Both SGs are attached to each interface endpoint so pods from either tier can reach AWS services.

Gateway endpoints (S3, DynamoDB) are route-table entries with no SG. They are added to both intra and private route tables so pods in both tiers can use them.

### VPC endpoints

Because intra subnets have no internet route, all AWS service communication requires VPC endpoints. The following endpoints are required for Fargate pods to function:

| Service | Endpoint type | Purpose |
|---------|--------------|---------|
| `ecr.api` | Interface | ECR image metadata |
| `ecr.dkr` | Interface | ECR image layer pulls |
| `s3` | Gateway | ECR stores image layers in S3 |
| `logs` | Interface | CloudWatch log delivery |
| `sts` | Interface | IRSA token exchange |
| `eks` | Interface | Cluster API communication |

A missing endpoint produces cryptic failures — pods stuck in `Pending` or containers failing with connection refused at startup. The endpoint list above is the minimum required set. The S3 gateway endpoint is free; interface endpoints have an hourly cost per AZ.

### NACLs
NACLs are defined explicitly rather than relying on default rules. This provides a network-layer defense-in-depth control and demonstrates understanding of the distinction between NACLs (stateless, subnet-level) and security groups (stateful, resource-level).

#### S3 gateway endpoint — NACL and security group behavior

ECR stores image layers in S3. When Fargate pulls an image, the ECR DKR endpoint handles the manifest lookup, but the actual layer data is fetched via presigned S3 URLs that resolve to **public S3 IP addresses** (e.g., `prod-us-east-2-starport-layer-bucket.s3.us-east-2.amazonaws.com`). This traffic is routed through the S3 gateway endpoint and never reaches the internet — intra subnets have no IGW or NAT route. However, both NACLs and security groups evaluate the raw destination IP before routing takes effect, so the public S3 IP range must be explicitly permitted at both layers even though the traffic stays within AWS.

**Security group:** The node security group egress rule uses the AWS-managed S3 prefix list (`com.amazonaws.us-east-2.s3`) via `prefix_list_ids`. This is precise and automatically stays current as AWS updates their IP ranges.

**NACLs:** NACLs cannot reference prefix lists — only CIDR blocks. The theoretically correct approach is to enumerate the S3 prefix list entries using the `aws_ec2_managed_prefix_list_entries` data source and create one `aws_network_acl_rule` per CIDR using `for_each`. This project uses `0.0.0.0/0` in the intra subnet NACL rules instead.

This is not simply a "good enough for a portfolio project" shortcut — `0.0.0.0/0` is actually the more operationally sound choice. AWS periodically updates the S3 prefix list as IP ranges change. During a `terraform apply` that reflects those changes, Terraform deletes old NACL rules and creates new ones, opening a window of partial S3 coverage. Any image pull during that window fails, and if the apply involves EKS resources, broken image pulls can cascade into failed deployments. The `0.0.0.0/0` rule never changes and carries none of that risk. The routing layer (no IGW, no NAT in intra subnets) is the durable compensating control — only gateway endpoint destinations are actually reachable regardless of what the NACL permits.

This outcome also validates the original decision to place EKS nodes and Fargate pods in intra subnets. At the time, the motivation was to eliminate internet egress from workloads as a security posture. In practice, it turned out that the S3 gateway endpoint behavior forces NACL rules that appear permissive on paper. The intra subnet design is what makes those rules safe — without an IGW or NAT route, `0.0.0.0/0` in a NACL is not a meaningful exposure. A cluster placed in private subnets with a NAT gateway would face the same NACL constraint but with actual internet routing present, making the permissive rules a genuine risk rather than a theoretical one.

### VPC flow logs
Flow logs are enabled and delivered to CloudWatch. This is a standard security and observability control — required in any real production environment for incident investigation and compliance.

## IAM ownership boundary

Pre-built modules (`terraform-aws-modules/eks`, `terraform-aws-modules/vpc`) are used for infrastructure provisioning. All IAM policy content remains caller-defined — modules may provision IAM resources but do not define policy documents.

Specifically:
- The EKS module is permitted to create the cluster OIDC provider
- All IRSA role trust policies and permission policies are defined in this codebase, consuming the OIDC provider ARN output from the EKS module
- Node group and cluster IAM roles follow the same pattern: role structure via module, policy content via caller-supplied documents

This maintains the security ownership principle established in the IAM module design: the operator controls what entities can do, not just that they exist.

## Terraform / Kubernetes Provisioning Coupling

A consequence of the Fargate + least-privilege SG design is that the EKS root
module carries responsibilities that would normally live outside
infrastructure-as-code — specifically Kubernetes namespace topology and
per-workload network policy.

Two mechanisms drive this coupling:

1. **Fargate profiles** must be provisioned in AWS before pods can schedule in
   a given namespace. This forces a `terraform apply` as a prerequisite for any
   new workload or cluster addon, and prevents a GitOps tool from fully
   bootstrapping itself from cold start.

2. **Per-namespace security groups** — our choice to replace the default shared
   cluster SG with scoped SGs via `SecurityGroupPolicy` means every new
   namespace with distinct network requirements produces work in two places: a
   new `aws_security_group` in terraform and a new `SecurityGroupPolicy`
   manifest in Kubernetes. The two resources are tightly coupled — the manifest
   references the SG ID produced by terraform.

This is an accepted trade-off. The alternatives (accepting the default shared
cluster SG, or using managed node groups) each sacrifice more than they gain for
this project's goals. The coupling is manageable at the current namespace count
and is explicit rather than hidden.

For a fuller discussion of the root causes, mitigations, and scaling
considerations, see:
[docs/lessons-learned/terraform-k8s-coupling.md](../lessons-learned/terraform-k8s-coupling.md)

## Pre-built vs DIY module split

| Component | Approach | Rationale |
|-----------|----------|-----------|
| VPC | `terraform-aws-modules/vpc` | Well-understood, implemented many times previously — not differentiating |
| EKS cluster + Fargate profiles | `terraform-aws-modules/eks` | Complex compute/networking configuration, not the learning focus |
| Cluster IAM role | DIY | Security surface — trust policy and permissions matter |
| Node IAM role | DIY | Defines what nodes can access — security-adjacent |
| OIDC provider | EKS module output consumed | Avoids duplicate resource; module exposes ARN for IRSA use |
| IRSA roles | DIY | Core learning objective; same pattern as existing OIDC role modules |