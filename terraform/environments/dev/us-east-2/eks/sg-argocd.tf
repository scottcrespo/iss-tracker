# ---------------------------------------------------------------------------
# argocd namespace security group
# ---------------------------------------------------------------------------
#
# Assigned to all argocd pods via SecurityGroupPolicy (SGP). On Fargate,
# the SGP-assigned SG REPLACES the cluster SG on the pod's branch ENI — it
# does not augment it. This SG must include every rule argocd pods need:
# cluster control plane ingress, intra-component traffic, DNS, and internet
# egress via NAT (repo-server requires internet to reach GitHub).
#
# The SGP manifest lives at:
#   k8s/argocd/manifests/bootstrap/sgp-argocd.yaml

resource "aws_security_group" "argocd" {
  #checkov:skip=CKV2_AWS_5: Attached to argocd pod ENIs via the Kubernetes SecurityGroupPolicy CRD (k8s/argocd/manifests/bootstrap/sgp-argocd.yaml). The attachment is made by the VPC CNI outside Terraform so Checkov cannot trace the reference.
  name        = "${local.cluster_name}-argocd"
  description = "argocd namespace pods - internet egress via NAT for Git access"
  vpc_id      = module.vpc.vpc_id
}

# Control plane → pod: all traffic. Required for exec, port-forward, and
# webhook calls initiated by the EKS control plane.
resource "aws_security_group_rule" "argocd_ingress_cluster" {
  description              = "Cluster control plane to argocd pods - all traffic"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.argocd.id
  source_security_group_id = module.eks.cluster_security_group_id
}

# Intra-component traffic: argocd-server, argocd-repo-server, argocd-application-
# controller, argocd-applicationset-controller, and redis all communicate within
# the namespace on various ports. All share this SG via SGP, so a self-referencing
# rule permits all intra-argocd traffic without enumerating individual ports.
resource "aws_security_group_rule" "argocd_ingress_self" {
  description              = "Intra-component traffic within argocd namespace"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.argocd.id
  source_security_group_id = aws_security_group.argocd.id
}

# HTTPS egress: covers VPC endpoint ENIs (ECR, STS, Secrets Manager) and
# internet via NAT (GitHub for repo-server, quay.io/ghcr.io for image pulls).
resource "aws_security_group_rule" "argocd_egress_https" {
  description       = "HTTPS to VPC endpoints and internet via NAT"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.argocd.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# DNS egress to CoreDNS. Both the VPC CIDR (pod IPs) and EKS service CIDR
# (ClusterIP 172.20.0.10) are required — Fargate SG evaluation sees the
# pre-DNAT destination so the service CIDR must be explicitly allowed.
resource "aws_security_group_rule" "argocd_egress_dns_udp" {
  description       = "DNS to CoreDNS - VPC and service CIDR (UDP)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = aws_security_group.argocd.id
  cidr_blocks       = [local.vpc_cidr, "172.20.0.0/16"]
}

resource "aws_security_group_rule" "argocd_egress_dns_tcp" {
  description       = "DNS to CoreDNS - VPC and service CIDR (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = aws_security_group.argocd.id
  cidr_blocks       = [local.vpc_cidr, "172.20.0.0/16"]
}

# Intra-component egress: argocd components communicate with each other within
# the namespace. Self-referencing egress permits outbound to peer pods sharing
# this SG without enumerating individual ports.
resource "aws_security_group_rule" "argocd_egress_self" {
  description              = "Intra-component egress within argocd namespace"
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.argocd.id
  source_security_group_id = aws_security_group.argocd.id
}