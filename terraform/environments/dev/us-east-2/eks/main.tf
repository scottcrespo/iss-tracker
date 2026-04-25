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

# Reads back the EKS cluster to obtain the primary (EKS-managed) security group
# ID. This SG is distinct from module.eks.cluster_security_group_id — EKS
# assigns it to all Fargate pods that have no SecurityGroupPolicy, including
# CoreDNS. Rules that must reach CoreDNS (DNS ingress) must target this SG.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

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
  eks_primary_sg_id       = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

