module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.18"

  name               = local.cluster_name
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.intra_subnets

  # Inject the cluster role we own rather than letting the module create one
  create_iam_role = false
  iam_role_arn    = aws_iam_role.eks_cluster.arn

  # Enable OIDC provider — required for IRSA
  enable_irsa = true

  # Grant the IAM identity that runs terraform apply cluster admin access.
  # Required to run kubectl commands as the same identity without a separate access entry.
  enable_cluster_creator_admin_permissions = true

  # Expose the cluster API endpoint to the VPC only — not the public internet.
  # Operators access the cluster via kubectl through the VPC (or a bastion).
  endpoint_public_access  = false
  endpoint_private_access = true

  # Fargate profiles — define which pods run on Fargate by namespace + label selector.
  # kube-system is included so CoreDNS runs on Fargate (required with no node groups).
  #
  # subnet_ids pins each profile to a specific subnet tier:
  #   kube-system → intra  (no internet egress needed; VPC endpoints cover all AWS calls)
  #   iss-tracker → private (poller needs internet egress to reach the public ISS API)
  #
  # Without explicit subnet_ids, EKS schedules pods across all subnets passed to the
  # cluster's subnet_ids, which would mix tiers and break the security boundary.
  fargate_profiles = {
    kube_system = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      subnet_ids   = module.vpc.intra_subnets
      selectors = [
        { namespace = "kube-system" }
      ]
    }
    iss_tracker = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      subnet_ids   = module.vpc.private_subnets
      selectors = [
        { namespace = "iss-tracker" }
      ]
    }
  }

  # Additional cluster security group rules — injected rather than hardcoded in module
  security_group_additional_rules = {
    ingress_nodes_443 = {
      description                = "Node/pod to cluster API"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Additional node security group rules
  node_security_group_additional_rules = {
    ingress_cluster_all = {
      description                   = "Cluster to node - all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_vpc_443 = {
      description = "HTTPS to VPC interface endpoints"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "egress"
      cidr_blocks = [local.vpc_cidr]
    }
  }
}

# ---------------------------------------------------------------------------
# Node SG — S3 egress via managed prefix list
# ---------------------------------------------------------------------------
#
# ECR image layers are served from S3 presigned URLs that resolve to public
# IPs (prod-us-east-2-starport-layer-bucket). Traffic is routed through the
# S3 gateway endpoint and never reaches the internet — intra subnets have no
# IGW or NAT. Security groups evaluate the raw destination IP before routing,
# so the S3 IP range must be permitted here even though traffic stays in AWS.
#
# Using the S3 managed prefix list (maintained by AWS) rather than 0.0.0.0/0
# ensures this rule is scoped to S3 IPs only and stays current automatically.

resource "aws_security_group_rule" "node_egress_s3" {
  description       = "HTTPS to S3 via gateway endpoint (ECR image layer pulls)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.eks.node_security_group_id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.s3.id]
}

# ---------------------------------------------------------------------------
# Private Fargate pod security group
# ---------------------------------------------------------------------------
#
# WHAT THIS SG IS
#
# The EKS module creates one "node security group" shared across all Fargate
# profiles. By default, every Fargate pod ENI gets that SG — regardless of
# which profile placed the pod or which subnet it landed in. The node SG has
# no internet egress, which is correct for kube-system pods in intra subnets.
#
# iss-tracker pods run in private subnets and need internet egress so the
# poller can reach the public ISS position API. They require different SG
# rules — specifically outbound 443/80 to 0.0.0.0/0 (via NAT gateway).
#
# HOW IT GETS ATTACHED
#
# AWS "Security Groups for Pods" (a VPC CNI feature) allows assigning a
# specific SG to pods matching a namespace/label selector via a
# SecurityGroupPolicy Kubernetes object. On Fargate, the assigned SG
# REPLACES the node SG on the pod's branch ENI — it does not augment it.
# This means this SG must include ALL rules the pod needs, not just the
# internet-egress ones.
#
# The SecurityGroupPolicy manifest lives at k8s/sgp-iss-tracker.yaml.
# It must be applied after the cluster is up and the iss-tracker namespace
# exists. The SG ID is injected at apply time using the Terraform output
# fargate_private_sg_id.
#
# WHY SEPARATE SGs RATHER THAN ADDING INTERNET EGRESS TO THE NODE SG
#
# Adding internet egress to the node SG would also give kube-system pods
# outbound internet access — violating least privilege. In practice, those
# pods are in intra subnets with no NAT route so they couldn't reach the
# internet anyway, but relying on routing as the sole control is weaker than
# having both routing AND SG enforce the boundary.

resource "aws_security_group" "fargate_private" {
  name        = "${local.cluster_name}-fargate-private"
  description = "Private Fargate pods (iss-tracker) - internet egress via NAT"
  vpc_id      = module.vpc.vpc_id
}

# Control plane → pod: all traffic. The EKS control plane uses the cluster SG
# to initiate connections to pods (e.g. exec, port-forward, webhook calls).
# This mirrors the ingress_cluster_all rule in node_security_group_additional_rules
# on the node SG, which we must replicate here since this SG replaces it.
resource "aws_security_group_rule" "fargate_private_ingress_cluster" {
  description              = "Cluster control plane to private pods - all traffic"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.fargate_private.id
  source_security_group_id = module.eks.cluster_security_group_id
}

# ALB → pod: the load balancer forwards requests to the API pod on port 8000.
# The ALB SG is created by the LB Controller and is not known at Terraform
# time, so we allow from the VPC CIDR. Security groups are stateful — the
# pod's response back to the ALB is automatically permitted without an
# explicit egress rule.
resource "aws_security_group_rule" "fargate_private_ingress_alb" {
  description       = "ALB to API pod on port 8000"
  type              = "ingress"
  from_port         = 8000
  to_port           = 8000
  protocol          = "tcp"
  security_group_id = aws_security_group.fargate_private.id
  cidr_blocks       = [local.vpc_cidr]
}

# HTTPS egress to 0.0.0.0/0 covers two distinct paths in a single rule:
#   1. VPC endpoint ENIs in intra subnets (10.0.51.x) — traffic stays within
#      the VPC; the route table sends it to the endpoint, not the internet.
#   2. Internet via NAT gateway — for the ISS position API.
# A separate vpc_cidr-scoped rule for path 1 would be redundant since
# 0.0.0.0/0 is a superset. The NAT gateway and routing table are the durable
# controls that enforce which path is actually taken.
resource "aws_security_group_rule" "fargate_private_egress_https" {
  description       = "HTTPS to VPC endpoints and internet via NAT"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.fargate_private.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# HTTP egress in case the ISS API or any dependency redirects HTTP → HTTPS.
resource "aws_security_group_rule" "fargate_private_egress_http" {
  description       = "HTTP to internet via NAT"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.fargate_private.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# DNS egress to CoreDNS pods in intra subnets. Kubernetes service discovery
# (kube-dns clusterIP) resolves to CoreDNS pod IPs (10.0.51.x). The SG is
# stateful so DNS responses are automatically permitted inbound.
resource "aws_security_group_rule" "fargate_private_egress_dns_udp" {
  description       = "DNS to CoreDNS in intra subnets (UDP)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = aws_security_group.fargate_private.id
  cidr_blocks       = [local.vpc_cidr]
}

resource "aws_security_group_rule" "fargate_private_egress_dns_tcp" {
  description       = "DNS to CoreDNS in intra subnets (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = aws_security_group.fargate_private.id
  cidr_blocks       = [local.vpc_cidr]
}