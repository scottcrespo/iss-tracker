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
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
}

