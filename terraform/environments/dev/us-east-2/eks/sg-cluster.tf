# ---------------------------------------------------------------------------
# Cluster SG — namespace-agnostic ingress rules
# ---------------------------------------------------------------------------
#
# The cluster SG is owned by the EKS module and governs traffic to CoreDNS
# and the EKS API server. By default it allows only intra-member traffic
# (cluster SG → cluster SG), which covers kube-system pods but excludes pods
# assigned a namespace SG via SecurityGroupPolicy.
#
# Rather than adding one rule per namespace SG, ingress is opened from the
# private subnet CIDR — the subnet tier used by all SGP-assigned namespaces
# (iss-tracker, argocd, and any future private namespace). The private subnets
# are cluster-dedicated; no non-Kubernetes workloads run there, so this
# provides equivalent security to per-namespace SG rules with no per-namespace
# maintenance burden.

resource "aws_security_group_rule" "cluster_ingress_private_subnets_api" {
  description       = "Private subnet pods to cluster API"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.eks.cluster_security_group_id
  cidr_blocks       = module.vpc.private_subnets_cidr_blocks
}

resource "aws_security_group_rule" "cluster_ingress_private_subnets_dns_udp" {
  description       = "DNS from private subnet pods to CoreDNS (UDP)"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = module.eks.cluster_security_group_id
  cidr_blocks       = module.vpc.private_subnets_cidr_blocks
}

resource "aws_security_group_rule" "cluster_ingress_private_subnets_dns_tcp" {
  description       = "DNS from private subnet pods to CoreDNS (TCP fallback)"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = module.eks.cluster_security_group_id
  cidr_blocks       = module.vpc.private_subnets_cidr_blocks
}