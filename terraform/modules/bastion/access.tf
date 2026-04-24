# ---------------------------------------------------------------------------
# EKS access entry - bastion role
# ---------------------------------------------------------------------------
#
# Grants the bastion IAM role cluster-admin access via the modern EKS access
# entry API (supersedes the legacy aws-auth ConfigMap pattern).
#
# Two coupled resources:
#   - access entry: registers the IAM principal as allowed to authenticate
#   - policy association: attaches an AWS-managed access policy for RBAC
#
# AmazonEKSClusterAdminPolicy grants full cluster admin at the Kubernetes
# level. Appropriate for an operator bastion; would be scoped down for
# multi-user / production shared bastions.

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# ---------------------------------------------------------------------------
# Cluster security group ingress - bastion to cluster API
# ---------------------------------------------------------------------------
#
# Allows kubectl and helm traffic from the bastion to the EKS private API
# endpoint on TCP/443. Attached to the caller-provided cluster SG; sources
# from local.bastion_sg_id which resolves whether the bastion SG is
# module-managed or externally supplied. Always created - the module owns
# this rule regardless of how the bastion SG itself was produced.

resource "aws_security_group_rule" "cluster_ingress_bastion" {
  description              = "Bastion to cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = local.bastion_sg_id
}