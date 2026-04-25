provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = {
      terraform_managed = "true"
      project           = "iss-tracker"
      environment       = "dev"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name = "iss-tracker-eks"
  vpc_cidr     = "10.0.0.0/16"
  # Aggregate CIDR for the private subnet tier. 10.0.0.0/17 is the exact
  # power-of-2-aligned parent block for all private /24s (10.0.0-2.0/24)
  # with room for future expansion. No unallocated ranges are included in
  # any other tier's address space. Any IP < 10.0.128.0 is private tier.
  private_subnets_aggregate = "10.0.0.0/17"
  # Aggregate CIDR for the intra subnet tier. 10.0.128.0/18 is the exact
  # parent block for all intra /24s (10.0.128-130.0/24). Together with the
  # public /18 (10.0.192.0/18), the three tiers partition 10.0.0.0/16 exactly:
  # /17 + /18 + /18 = /16 — no gaps, no overlap.
  intra_subnets_aggregate = "10.0.128.0/18"
  account_id              = data.aws_caller_identity.current.account_id
  region                  = data.aws_region.current.name
  # module.eks.cluster_primary_security_group_id is the EKS-managed SG that
  # EKS auto-assigns to all Fargate pods without a SecurityGroupPolicy (including
  # CoreDNS). Distinct from module.eks.cluster_security_group_id, which is the
  # module-managed node-to-control-plane SG. Using the module output avoids a
  # data source read-back that fails on fresh apply before the cluster exists.
  eks_primary_sg_id = module.eks.cluster_primary_security_group_id
}

