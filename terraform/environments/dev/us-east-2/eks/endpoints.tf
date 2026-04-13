# ---------------------------------------------------------------------------
# VPC Endpoints
# ---------------------------------------------------------------------------
#
# Interface endpoints place ENIs in the intra subnets so all AWS service
# traffic stays within the VPC CIDR — no internet route required.
# The S3 endpoint is a gateway type (free); all others are interface type.
#
# Security group rules are caller-defined and injected into the module.

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.cluster_name}-vpc-endpoints"
  description = "Allow HTTPS from within the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "Allow all outbound within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.6.1"

  vpc_id = module.vpc.vpc_id

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  endpoints = {
    # S3 — gateway endpoint (free, required for ECR image layer pulls)
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.intra_route_table_ids
    }
    # DynamoDB — gateway endpoint (free, required for app workload data access)
    dynamodb = {
      service         = "dynamodb"
      service_type    = "Gateway"
      route_table_ids = module.vpc.intra_route_table_ids
    }
    # ECR API — image metadata
    ecr_api = {
      service             = "ecr.api"
      service_type        = "Interface"
      subnet_ids          = module.vpc.intra_subnets
      private_dns_enabled = true
    }
    # ECR DKR — image layer pulls
    ecr_dkr = {
      service             = "ecr.dkr"
      service_type        = "Interface"
      subnet_ids          = module.vpc.intra_subnets
      private_dns_enabled = true
    }
    # CloudWatch Logs — container and flow log delivery
    logs = {
      service             = "logs"
      service_type        = "Interface"
      subnet_ids          = module.vpc.intra_subnets
      private_dns_enabled = true
    }
    # STS — IRSA token exchange
    sts = {
      service             = "sts"
      service_type        = "Interface"
      subnet_ids          = module.vpc.intra_subnets
      private_dns_enabled = true
    }
    # EKS — cluster API communication
    eks = {
      service             = "eks"
      service_type        = "Interface"
      subnet_ids          = module.vpc.intra_subnets
      private_dns_enabled = true
    }
  }
}