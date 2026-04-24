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
  cluster_name       = "iss-tracker-eks"
  vpc_cidr           = "10.0.0.0/16"
  account_id         = data.aws_caller_identity.current.account_id
  region             = data.aws_region.current.name
  eks_primary_sg_id  = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

