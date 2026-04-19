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

## Summary

Private EKS clusters with Fargate and no NAT are significantly more operationally
complex than the AWS documentation implies. Every AWS API call from a pod or
controller must route through a VPC endpoint. SG and NACL rules must be reasoned
about explicitly because there is no node-level NAT to absorb mistakes. The
payoff is a cluster with no internet egress and a very small blast radius — but
expect to spend meaningful time on initial setup.