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

# Used to scope the node security group S3 egress rule to the S3 managed
# prefix list rather than 0.0.0.0/0. The prefix list is maintained by AWS
# and always contains the current S3 IP ranges for the region.
data "aws_ec2_managed_prefix_list" "s3" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${local.region}.s3"]
  }
}

locals {
  cluster_name = "iss-tracker-eks"
  vpc_cidr     = "10.0.0.0/16"
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
}

