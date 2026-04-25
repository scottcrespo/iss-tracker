module "eks" {
  # commit hash of v21.18.0
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=312ddb68f408ef045a03d3673f5dabeeed5b5cf0"

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

  # CoreDNS must be installed as an explicit managed add-on on Fargate-only
  # clusters — EKS does not auto-deploy it without EC2 node groups present.
  addons = {
    coredns = {
      most_recent = true
    }
  }

  # Envelope encryption for Kubernetes secrets at rest.
  # The EKS control plane uses this key to encrypt secrets before writing to
  # etcd and decrypt them on read. Key is defined in kms.tf.
  encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks_secrets.arn
  }

  # Fargate-only cluster — no EC2 node groups. The node SG is unused on
  # Fargate: pod ENIs get the cluster SG by default, or a namespace SG via
  # SecurityGroupPolicy. Disabling prevents dead security group resources.
  create_node_security_group = false

  # Fargate profiles — define which pods run on Fargate by namespace + label selector.
  # kube-system is included so CoreDNS runs on Fargate (required with no node groups).
  #
  # subnet_ids pins each profile to a specific subnet tier:
  #   kube-system → intra  (no internet egress needed; VPC endpoints cover all AWS calls)
  #   iss-tracker → private (poller needs internet egress to reach the public ISS API)
  #   argocd      → private (repo-server needs internet egress to reach GitHub)
  #
  # Without explicit subnet_ids, EKS schedules pods across all subnets passed to the
  # cluster's subnet_ids, which would mix tiers and break the security boundary.
  fargate_profiles = {
    kube_system = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      subnet_ids   = module.vpc.intra_subnets
      selectors = [
        { namespace = "kube-system" }
      ]
    }
    iss_tracker = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      subnet_ids   = module.vpc.private_subnets
      selectors = [
        { namespace = "iss-tracker" }
      ]
    }
    argocd = {
      iam_role_arn = aws_iam_role.eks_fargate.arn
      subnet_ids   = module.vpc.private_subnets
      selectors = [
        { namespace = "argocd" }
      ]
    }
  }
}