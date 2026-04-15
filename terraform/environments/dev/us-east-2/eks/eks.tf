module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.18"

  name               = local.cluster_name
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.intra_subnets

  # Inject the cluster role we own rather than letting the module create one
  create_iam_role = false
  iam_role_arn    = aws_iam_role.eks_cluster.arn

  # Enable OIDC provider — required for IRSA
  enable_irsa = true

  # Grant the IAM identity that runs terraform apply cluster admin access.
  # Required to run kubectl commands as the same identity without a separate access entry.
  enable_cluster_creator_admin_permissions = true

  # Expose the cluster API endpoint to the VPC only — not the public internet.
  # Operators access the cluster via kubectl through the VPC (or a bastion).
  endpoint_public_access  = false
  endpoint_private_access = true

  # Fargate profiles — define which pods run on Fargate by namespace + label selector.
  # kube-system is included so CoreDNS runs on Fargate (required with no node groups).
  fargate_profiles = {
    kube_system = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      selectors = [
        { namespace = "kube-system" }
      ]
    }
    iss_tracker = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      selectors = [
        { namespace = "iss-tracker" }
      ]
    }
  }

  # Additional cluster security group rules — injected rather than hardcoded in module
  security_group_additional_rules = {
    ingress_nodes_443 = {
      description                = "Node/pod to cluster API"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Additional node security group rules
  node_security_group_additional_rules = {
    ingress_cluster_all = {
      description                   = "Cluster to node - all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_vpc_443 = {
      description = "HTTPS to VPC interface endpoints"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "egress"
      cidr_blocks = [local.vpc_cidr]
    }
  }
}

# ---------------------------------------------------------------------------
# Node SG — S3 egress via managed prefix list
# ---------------------------------------------------------------------------
#
# ECR image layers are served from S3 presigned URLs that resolve to public
# IPs (prod-us-east-2-starport-layer-bucket). Traffic is routed through the
# S3 gateway endpoint and never reaches the internet — intra subnets have no
# IGW or NAT. Security groups evaluate the raw destination IP before routing,
# so the S3 IP range must be permitted here even though traffic stays in AWS.
#
# Using the S3 managed prefix list (maintained by AWS) rather than 0.0.0.0/0
# ensures this rule is scoped to S3 IPs only and stays current automatically.

resource "aws_security_group_rule" "node_egress_s3" {
  description       = "HTTPS to S3 via gateway endpoint (ECR image layer pulls)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.eks.node_security_group_id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.s3.id]
}