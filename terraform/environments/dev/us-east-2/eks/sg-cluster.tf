# ---------------------------------------------------------------------------
# EKS primary (EKS-managed) SG — ingress from private subnet pods
# ---------------------------------------------------------------------------
#
# EKS assigns the primary SG (eks-cluster-sg-*) to all Fargate pods that have
# no SecurityGroupPolicy, including CoreDNS in kube-system. This is distinct
# from module.eks.cluster_security_group_id, which is an additional SG created
# by the terraform-aws-modules/eks module and is NOT used by CoreDNS or other
# kube-system pods.
#
# The primary SG ID is not exposed as a module output and must be read back via
# the aws_eks_cluster data source in main.tf as local.eks_primary_sg_id.
#
# Ingress is opened from each private subnet CIDR individually using for_each
# so each AWS rule maps to exactly one Terraform resource — avoids the
# multi-CIDR list issue with aws_security_group_rule and keeps state clean.
#
# Two rule sets are required:
#   - DNS (UDP + TCP 53): private subnet pods → CoreDNS
#   - API (TCP 443): private subnet pods → EKS API server

resource "aws_security_group_rule" "primary_sg_ingress_private_subnets_dns_udp" {
  for_each = toset(module.vpc.private_subnets_cidr_blocks)

  description       = "DNS from private subnet pods to CoreDNS (UDP) - ${each.value}"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = local.eks_primary_sg_id
  cidr_blocks       = [each.value]
}

resource "aws_security_group_rule" "primary_sg_ingress_private_subnets_dns_tcp" {
  for_each = toset(module.vpc.private_subnets_cidr_blocks)

  description       = "DNS from private subnet pods to CoreDNS (TCP fallback) - ${each.value}"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = local.eks_primary_sg_id
  cidr_blocks       = [each.value]
}

resource "aws_security_group_rule" "primary_sg_ingress_private_subnets_api" {
  for_each = toset(module.vpc.private_subnets_cidr_blocks)

  description       = "Private subnet pods to EKS API server - ${each.value}"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.eks_primary_sg_id
  cidr_blocks       = [each.value]
}