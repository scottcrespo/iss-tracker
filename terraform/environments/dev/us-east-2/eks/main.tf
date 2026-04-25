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
  cluster_name             = "iss-tracker-eks"
  vpc_cidr                 = "10.0.0.0/16"
  # Aggregate CIDR covering only the private subnet tier (10.0.0-3.0/24).
  # Used in intra NACL rules to avoid permitting public subnets (10.0.101.x)
  # into the intra tier. Excludes intra (10.0.51.x) and public (10.0.101.x).
  private_subnets_aggregate = "10.0.0.0/22"
  # Aggregate CIDR covering all three intra subnets (10.0.51.0/24, 10.0.52.0/24,
  # 10.0.53.0/24). 10.0.48.0/21 is the smallest /21-aligned block (48 is a
  # multiple of 8) containing all three; ranges 10.0.48-50.x and 10.0.54-55.x
  # are unallocated and unreachable in this VPC. Used to stay within the AWS
  # 20-rule NACL limit while keeping intra-to-intra traffic rules explicit.
  intra_subnets_aggregate = "10.0.48.0/21"
  account_id               = data.aws_caller_identity.current.account_id
  region                   = data.aws_region.current.name
  eks_primary_sg_id        = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

