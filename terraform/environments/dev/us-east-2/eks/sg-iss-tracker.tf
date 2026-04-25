# ---------------------------------------------------------------------------
# iss-tracker namespace security group
# ---------------------------------------------------------------------------
#
# Assigned to all iss-tracker pods via SecurityGroupPolicy (SGP). On Fargate,
# the SGP-assigned SG REPLACES the cluster SG on the pod's branch ENI — it
# does not augment it. This SG must therefore include every rule the pod needs:
# cluster control plane ingress, DNS, and internet egress via NAT.
#
# The SGP manifest lives at:
#   k8s/iss-tracker/manifests/bootstrap/sgp-iss-tracker.yaml
#
# Run terraform state mv before applying if renaming from fargate_private:
#   terraform state mv \
#     aws_security_group.fargate_private \
#     aws_security_group.iss_tracker

resource "aws_security_group" "iss_tracker" {
  #checkov:skip=CKV2_AWS_5: Attached to iss-tracker pod ENIs via the Kubernetes SecurityGroupPolicy CRD (k8s/iss-tracker/manifests/bootstrap/sgp-iss-tracker.yaml). The attachment is made by the VPC CNI outside Terraform so Checkov cannot trace the reference.
  name        = "${local.cluster_name}-iss-tracker"
  description = "iss-tracker namespace pods - internet egress via NAT"
  vpc_id      = module.vpc.vpc_id
}

# Control plane → pod: all traffic. The EKS control plane uses the cluster SG
# to initiate connections to pods (exec, port-forward, webhook calls).
resource "aws_security_group_rule" "iss_tracker_ingress_cluster" {
  description              = "Cluster control plane to iss-tracker pods - all traffic"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.iss_tracker.id
  source_security_group_id = local.eks_primary_sg_id
}

# ALB → pod: the load balancer forwards requests to the API pod on port 8000.
# The ALB SG is created by the LB Controller and is not known at Terraform
# time, so we allow from the VPC CIDR. SGs are stateful — response traffic
# is automatically permitted.
resource "aws_security_group_rule" "iss_tracker_ingress_alb" {
  description       = "ALB to API pod on port 8000"
  type              = "ingress"
  from_port         = 8000
  to_port           = 8000
  protocol          = "tcp"
  security_group_id = aws_security_group.iss_tracker.id
  cidr_blocks       = [local.vpc_cidr]
}

# HTTPS egress to 0.0.0.0/0 covers two paths in a single rule:
#   1. VPC endpoint ENIs in intra subnets — traffic stays within the VPC
#   2. Internet via NAT gateway — for the ISS position API
# The NAT gateway and routing table are the durable controls that enforce
# which path is actually taken.
resource "aws_security_group_rule" "iss_tracker_egress_https" {
  description       = "HTTPS to VPC endpoints and internet via NAT"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.iss_tracker.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# HTTP egress in case the ISS API or any dependency redirects HTTP to HTTPS.
resource "aws_security_group_rule" "iss_tracker_egress_http" {
  description       = "HTTP to internet via NAT"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.iss_tracker.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# DNS egress to CoreDNS via the kube-dns ClusterIP (172.20.0.10) and pod IPs.
# Both CIDRs are needed: the ClusterIP is in the EKS service CIDR (172.20.0.0/16)
# which is outside vpc_cidr. On Fargate, SG evaluation sees the pre-DNAT
# destination so the service CIDR must be explicitly allowed.
resource "aws_security_group_rule" "iss_tracker_egress_dns_udp" {
  description       = "DNS to CoreDNS - VPC and service CIDR (UDP)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = aws_security_group.iss_tracker.id
  cidr_blocks       = [local.vpc_cidr, "172.20.0.0/16"]
}

resource "aws_security_group_rule" "iss_tracker_egress_dns_tcp" {
  description       = "DNS to CoreDNS - VPC and service CIDR (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = aws_security_group.iss_tracker.id
  cidr_blocks       = [local.vpc_cidr, "172.20.0.0/16"]
}