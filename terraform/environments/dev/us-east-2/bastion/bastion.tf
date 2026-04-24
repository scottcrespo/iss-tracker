# ---------------------------------------------------------------------------
# Bastion host for kubectl/helm access to the private EKS cluster
# ---------------------------------------------------------------------------
#
# Factored out of the EKS root into its own environment root so the bastion
# can be destroyed and re-provisioned independently (e.g., to refresh the
# AMI or user_data) without touching cluster state, and so the same module
# can be instantiated per-environment as staging and prod come online.
#
# The module is sourced from the in-repo modules/bastion directory. When
# this module is stabilized and other repos consume it, switch the source
# to a git ref pinned to a commit SHA per the module-pinning convention.

module "bastion" {
  source = "../../../../modules/bastion"

  name_prefix               = local.name_prefix
  vpc_id                    = local.vpc_id
  bastion_subnet_id         = local.private_subnet_ids[0]
  eice_subnet_id            = local.private_subnet_ids[0]
  cluster_name              = local.cluster_name
  cluster_security_group_id = local.cluster_security_group_id
  region                    = local.region
  repo_url                  = "https://github.com/scottcrespo/iss-tracker.git"

  iam_policies = {
    eks_describe = data.aws_iam_policy_document.bastion_eks_describe.json
  }
}

# ---------------------------------------------------------------------------
# Bastion IAM policy - caller-defined per IAM Governance
# ---------------------------------------------------------------------------
#
# Grants the bastion role the minimum permissions needed for `aws eks
# update-kubeconfig` and for kubectl to authenticate against the cluster.
# Policy content is defined here (the root module that owns the trust
# relationship) and injected into the bastion module via var.iam_policies.
#
# ec2:DescribeSecurityGroups uses Resource="*" because EC2 Describe
# actions do not support resource-level restrictions at the AWS API
# level - see the checkov skip below.

data "aws_iam_policy_document" "bastion_eks_describe" {
  statement {
    sid       = "AllowEKSDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.cluster_name}"]
  }

  statement {
    sid       = "AllowIAMGetRole"
    effect    = "Allow"
    actions   = ["iam:GetRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.cluster_name}-*"]
  }

  statement {
    #checkov:skip=CKV_AWS_356: ec2:DescribeSecurityGroups does not support resource-level restrictions - AWS requires Resource="*" for all EC2 Describe actions.
    sid       = "AllowEC2DescribeSecurityGroups"
    effect    = "Allow"
    actions   = ["ec2:DescribeSecurityGroups"]
    resources = ["*"]
  }
}