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

# Pulls VPC, subnet, and cluster identifiers from the EKS root's state.
# The cluster security group ID and Fargate-profile-bound subnet IDs are
# not easily discoverable by tag, so remote state is the cleanest source
# of truth. The EKS root owns these values; this root consumes them.
data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "iss-tracker-tfstate-dev"
    key    = "dev/us-east-2/eks/terraform.tfstate"
    region = "us-east-2"
  }
}

locals {
  name_prefix = "iss-tracker-eks"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  vpc_id                    = data.terraform_remote_state.eks.outputs.vpc_id
  private_subnet_ids        = data.terraform_remote_state.eks.outputs.private_subnet_ids
  cluster_name              = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_security_group_id = data.terraform_remote_state.eks.outputs.cluster_security_group_id
}