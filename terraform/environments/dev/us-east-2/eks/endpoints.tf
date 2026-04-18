# ---------------------------------------------------------------------------
# VPC Endpoints
# ---------------------------------------------------------------------------
#
# Interface endpoint ENIs are placed in intra subnets only. Private subnet
# pods reach them via VPC-local routing (all subnets share the 10.0.0.0/16
# address space; no cross-subnet route entry is needed).
#
# Two dedicated security groups scope endpoint access by subnet tier:
#   vpc_endpoints_intra   — accepts HTTPS from intra subnet CIDRs (kube-system)
#   vpc_endpoints_private — accepts HTTPS from private subnet CIDRs (iss-tracker)
# Both SGs are attached to every interface endpoint so pods in either tier
# can resolve and reach AWS services.
#
# Gateway endpoints (S3, DynamoDB) are route-table entries, not ENIs — they
# carry no SG and must be added to both the intra and private route tables.

resource "aws_security_group" "vpc_endpoints_intra" {
  #checkov:skip=CKV2_AWS_5: Attached to all interface VPC endpoint ENIs via module.vpc_endpoints security_group_ids. The attachment is inside a third-party module so Checkov cannot trace the reference.
  name        = "${local.cluster_name}-vpc-endpoints-intra"
  description = "VPC endpoints - HTTPS from intra subnets (kube-system pods)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from intra subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = module.vpc.intra_subnets_cidr_blocks
  }

  egress {
    description = "All outbound within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }
}

resource "aws_security_group" "vpc_endpoints_private" {
  #checkov:skip=CKV2_AWS_5: Attached to all interface VPC endpoint ENIs via module.vpc_endpoints security_group_ids. The attachment is inside a third-party module so Checkov cannot trace the reference.
  name        = "${local.cluster_name}-vpc-endpoints-private"
  description = "VPC endpoints - HTTPS from private subnets (iss-tracker pods)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from private subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  egress {
    description = "All outbound within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }
}

module "vpc_endpoints" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git//modules/vpc-endpoints?ref=7a28ce8ec6a17a8ca52710e47763f3a52c155110"
  vpc_id = module.vpc.vpc_id

  security_group_ids = [
    aws_security_group.vpc_endpoints_intra.id,
    aws_security_group.vpc_endpoints_private.id,
  ]

  endpoints = {
    # S3 — gateway endpoint (free, required for ECR image layer pulls).
    # Added to private route tables so iss-tracker pods can pull images.
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = concat(module.vpc.intra_route_table_ids, module.vpc.private_route_table_ids)
    }
    # DynamoDB — gateway endpoint (free, required for app workload data access).
    # Added to private route tables so API and poller pods can reach DynamoDB.
    dynamodb = {
      service         = "dynamodb"
      service_type    = "Gateway"
      route_table_ids = concat(module.vpc.intra_route_table_ids, module.vpc.private_route_table_ids)
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