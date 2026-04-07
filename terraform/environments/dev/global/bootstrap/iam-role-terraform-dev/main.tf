provider "aws" {
  region = "us-east-2"
}

# get account ID without having to store it
data "aws_caller_identity" "current" {}

# get current aws region
data "aws_region" "current" {}

module "terraform_role" {
  source = "../../../../../modules/iam-terraform-role"

  account_id  = data.aws_caller_identity.current.account_id
  environment = "dev"
  permission_boundary_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
  ]
  project_scope_limit_prefix = "iss-tracker"
  region                     = data.aws_region.current.name
  tags = {
    environment = "dev"
  }
  terraform_role_allowed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccessV2",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess",
  ]

}