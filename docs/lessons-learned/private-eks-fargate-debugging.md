# Lessons Learned: Private EKS + Fargate + Intra Subnets

Accumulated from debugging sessions while standing up the iss-tracker cluster.
Cluster configuration: EKS on Fargate, no NAT gateway, intra subnets for system
workloads (kube-system), private subnets for app workloads (iss-tracker).

---

## 1. Fargate Security Group Architecture

### What we expected
EKS node security group rules would apply to Fargate pods.

### What's actually true
On a Fargate-only cluster, **all pods use the cluster security group by default**
(`eks-cluster-sg-*`), not the node SG. The cluster SG only allows all traffic
from itself (self-referencing rule). Any pod in a different SG that tries to
reach a pod in the cluster SG — including CoreDNS — will be REJECTED unless
you explicitly add the cross-SG rule.

### What bit us
- DNS rules were added to the node SG. No Fargate pod ever uses the node SG.
- `SecurityGroupPolicy` was used to assign `fargate_private` SG to app pods,
  replacing the cluster SG. DNS from `fargate_private` → cluster SG was REJECTED.
- VPC flow logs showed REJECT on port 53; `aws ec2 describe-network-interfaces`
  on the CoreDNS pod ENI confirmed it held the cluster SG, not the node SG.

### Fix
Add explicit UDP/TCP 53 ingress rules to the **cluster SG**, sourced from any
custom Fargate SG:

```hcl
resource "aws_security_group_rule" "cluster_ingress_fargate_private_dns_udp" {
  type                     = "ingress"
  from_port                = 53
  to_port                  = 53
  protocol                 = "udp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = aws_security_group.fargate_private.id
}
```

### Debugging tools
```bash
# Identify which SG is attached to a pod ENI
aws ec2 describe-network-interfaces \
  --filters "Name=private-ip-address,Values=<pod-ip>" \
  --query "NetworkInterfaces[*].Groups"

# Flow logs query (CloudWatch Logs Insights)
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action = "REJECT" and srcAddr like "10.0.2."
| sort @timestamp desc
```

---

## 2. NACLs Are Stateless — Ephemeral Ports Matter

### What bit us
The intra subnet NACL was missing a rule to allow **inbound** UDP ephemeral port
traffic (1024-65535). CoreDNS forwards external queries to the VPC DNS resolver
at `<vpc-cidr-base>.2:53`. The resolver responds with UDP from port 53 to
CoreDNS's ephemeral port. Because NACLs are stateless, the response path must be
explicitly allowed.

### Fix
Add an inbound ephemeral UDP rule to the intra NACL:

```hcl
{
  rule_number = "125"
  rule_action = "allow"
  protocol    = "udp"
  from_port   = "1024"
  to_port     = "65535"
  cidr_block  = local.vpc_cidr
}
```

### Rule of thumb
For every UDP service call that crosses a NACL boundary, ask: where does the
**response** come from, and on what port? The answer is always an ephemeral port
on the caller's side. That inbound path needs its own NACL rule.

---

## 3. VPC Endpoints: Discover Them One Timeout at a Time

Private clusters with no NAT gateway require a VPC interface endpoint for every
AWS service API the cluster needs to reach. The challenge: there is no
comprehensive list of which endpoints a given controller requires — you find out
when a pod times out trying to reach `<service>.us-east-2.amazonaws.com`.

### Endpoints required for this cluster

| Endpoint | Required by | Why |
|----------|-------------|-----|
| `ecr.api` | Kubelet (all nodes) | Image metadata |
| `ecr.dkr` | Kubelet (all nodes) | Image layer pulls |
| `s3` (Gateway) | Kubelet (all nodes) | ECR layer storage |
| `sts` | IRSA (all pods) | Token exchange |
| `logs` | Fluent Bit / node agent | CloudWatch log delivery |
| `eks` | Cluster API communication | Control plane |
| `elasticloadbalancing` | AWS Load Balancer Controller | ALB/NLB API |
| `ec2` | AWS Load Balancer Controller | Subnet and SG discovery |
| `dynamodb` (Gateway) | App pods | DynamoDB data plane |

### Debugging pattern
```bash
# Check if a timeout is hitting a public endpoint
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  --tail=100 | grep "i/o timeout"

# Confirm an endpoint is available
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-2.<service>" \
  --query "VpcEndpoints[*].{State:State,Id:VpcEndpointId}"
```

### After adding an endpoint
The controller may need a restart to clear cached connection state:
```bash
kubectl rollout restart deployment -n kube-system aws-load-balancer-controller
```

---

## 4. AWS Load Balancer Controller IAM Policy Drift

### What happened
The IAM policy for the LB controller was based on the official AWS reference
policy. That policy has lagged behind what newer controller versions actually
call. Two specific gaps:

**Gap 1: `AddTags` on newly-created resources**

The reference policy's `AddTags` statement requires the resource to *already*
have the `elbv2.k8s.aws/cluster` tag. A brand-new target group has no tags yet,
so the condition fails. The fix is a second `AddTags` statement scoped to the
creation context:

```hcl
{
  Sid    = "AllowELBTagsOnCreate"
  Effect = "Allow"
  Action = ["elasticloadbalancing:AddTags"]
  Resource = [
    "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
    "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
    "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
  ]
  Condition = {
    StringEquals = {
      "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
    }
    Null = {
      "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
    }
  }
}
```

**Gap 2: `DescribeListenerAttributes`**

Not present in the reference policy at the time of writing. Add it to the
`elasticloadbalancing:Describe*` block.

### General advice
When an IAM `AccessDenied` error appears in the LB controller logs, check the
error for the exact action name and add it. The pattern recurs on major version
upgrades of the controller.

---

## 5. Subnet Tagging for ALB Auto-Discovery

The LB controller discovers subnets by tag, not by explicit configuration.
Without the correct tags, `DescribeSubnets` returns results but the controller
finds no eligible subnets and silently builds an empty model (no ALB created,
no error event on the ingress).

| Subnet tier | Required tag | Value | ALB type |
|-------------|-------------|-------|----------|
| Public | `kubernetes.io/role/elb` | `1` | Internet-facing |
| Private/Intra | `kubernetes.io/role/internal-elb` | `1` | Internal |
| All tiers | `kubernetes.io/cluster/<cluster-name>` | `shared` | Both |

Verify the tags are actually applied in AWS (not just in terraform):
```bash
aws ec2 describe-subnets \
  --filters "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query "Subnets[*].{Id:SubnetId,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table
```

---

## 6. Terraform State Drift

Several security group rules and NACL entries that existed in the terraform
config were not reflected in actual AWS state — terraform reported no changes
but the rules were not present. Root cause was likely interrupted or partially
failed applies over multiple sessions.

### When to suspect state drift
- A rule exists in `.tf` files but traffic is still being REJECTED
- `terraform plan` reports no changes despite a known missing resource
- Manual AWS CLI inspection reveals the rule is absent

### Fix
```bash
# Add the missing rule manually to unblock, then reconcile state
aws ec2 authorize-security-group-ingress \
  --group-id <sg-id> \
  --protocol udp --port 53 \
  --source-group <source-sg-id>

# Then import or taint to force terraform to reconcile
terraform import aws_security_group_rule.<name> <sg-id>_ingress_...
```

---

## 7. aws_security_group_rule Multi-CIDR Anti-Pattern

### What happened
During a cluster SG refactor, `aws_security_group_rule` resources were written
with a list of CIDRs in `cidr_blocks`:

```hcl
resource "aws_security_group_rule" "cluster_ingress_dns_udp" {
  cidr_blocks = module.vpc.private_subnets_cidr_blocks  # list of 3 CIDRs
  ...
}
```

AWS creates one rule per CIDR in the list, but terraform tracks them as a single
resource. After a `terraform state rm` + manual CLI add + config rewrite cycle,
`terraform apply` reported `InvalidPermission.Duplicate` for all rules — terraform
tried to create rules that already existed, but state didn't know about them.

### The two-SG-ID trap
Debugging was complicated by a second issue: EKS exposes two different security
group IDs and it is easy to describe the wrong one.

| Source | SG ID | What it is |
|--------|-------|------------|
| `aws eks describe-cluster ... .clusterSecurityGroupId` | `sg-090f...` | EKS-managed control plane SG |
| `terraform output cluster_security_group_id` | `sg-004c...` | terraform-aws-modules cluster SG — what Fargate pods and sg-cluster.tf actually use |

We were running `describe-security-group-rules` against the EKS-managed SG and
seeing no per-subnet rules, while terraform was correctly targeting the module SG
where the rules already existed. The contradiction ("rules don't exist" from
describe, "duplicate" from apply) was caused entirely by describing the wrong SG.

### Fix
1. Always verify the SG ID terraform is targeting with `terraform output cluster_security_group_id` before inspecting rules with the AWS CLI.
2. Use `for_each` over a set of CIDRs — one resource per CIDR, clean state:

```hcl
resource "aws_security_group_rule" "cluster_ingress_private_subnets_dns_udp" {
  for_each = toset(module.vpc.private_subnets_cidr_blocks)

  cidr_blocks       = [each.value]
  security_group_id = module.eks.cluster_security_group_id
  ...
}
```

3. Import the existing AWS rules into the new `for_each` resources:

```bash
# Import format: SGID_TYPE_PROTOCOL_FROMPORT_TOPORT_CIDR
terraform import \
  'aws_security_group_rule.cluster_ingress_private_subnets_dns_udp["10.0.1.0/24"]' \
  sg-004c62e65be079f87_ingress_udp_53_53_10.0.1.0/24
```

### Rule of thumb
Never use a list in `cidr_blocks` on `aws_security_group_rule`. Each CIDR must
be its own resource (via `for_each`) so terraform can track, import, and reconcile
each AWS rule independently.

---

## 8. NACL Rules: Scope to Subnet Tiers, Not the Full VPC CIDR

### What happened
When opening DNS (UDP/TCP 53) across the intra ↔ private subnet boundary, the
proposed NACL rule used `vpc_cidr` (e.g., `10.0.0.0/16`) as the source/destination.
This was flagged as too permissive: the VPC CIDR includes public subnets, which
should have no direct path into the intra tier where kube-system workloads run.

### Why vpc_cidr is wrong for intra-tier NACLs
NACLs are the last stateless enforcement layer before routing. Allowing the full
`vpc_cidr` on intra subnet NACLs grants implicit access from public subnets,
undermining the defense-in-depth model where each tier has distinct trust. A
misconfigured public-facing resource (e.g., a future ALB misroute) would then
have a NACL-permitted path into the cluster control plane tier.

### The right scope
NACL rules between tiers should be scoped to the specific subnet CIDRs that
legitimately need to communicate:

| Traffic | NACL source/destination |
|---------|------------------------|
| Private pods → intra CoreDNS (53) | private subnet CIDRs only |
| Intra CoreDNS responses → private pods (ephemeral) | private subnet CIDRs only |
| Private pods → intra VPC endpoints (443) | private subnet CIDRs only |

**Never use `vpc_cidr` for intra-tier NACL rules.** Enumerate the private subnet
CIDRs explicitly, or use a dedicated local that represents only the private tier.

### Rule of thumb
When writing a NACL rule, ask: which subnet tier actually originates this traffic?
Scope the rule to that tier's CIDRs. If the answer is "anything in the VPC," that
is a signal to re-examine the architecture, not a justification for a broad rule.

---

## Summary

Private EKS clusters with Fargate and no NAT are significantly more operationally
complex than the AWS documentation implies. Every AWS API call from a pod or
controller must route through a VPC endpoint. SG and NACL rules must be reasoned
about explicitly because there is no node-level NAT to absorb mistakes. The
payoff is a cluster with no internet egress and a very small blast radius — but
expect to spend meaningful time on initial setup.

Two terraform anti-patterns compound the complexity: using `cidr_blocks` lists
in `aws_security_group_rule` (breaks state tracking) and inspecting the wrong
SG ID when debugging (EKS exposes two; terraform uses the module-managed one).
Both are documented in sections 6 and 7 above.