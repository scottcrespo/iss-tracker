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

module "ecr_api" {
  source          = "../../../../modules/ecr"
  repository_name = "iss-tracker-api"
}

module "ecr_poller" {
  source          = "../../../../modules/ecr"
  repository_name = "iss-tracker-poller"
}