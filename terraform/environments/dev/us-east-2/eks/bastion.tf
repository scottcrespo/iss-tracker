# ---------------------------------------------------------------------------
# Bastion — EC2 Instance Connect Endpoint
# ---------------------------------------------------------------------------
#
# A minimal EC2 instance used for kubectl and helm operations against the
# private EKS endpoint. Accessed via EC2 Instance Connect Endpoint (EICE) —
# SSH over private IP, no SSM agent required, no public key management.
#
# Placement: private subnet. NAT gateway provides outbound internet so user
# data can download kubectl and helm on first boot. No public IP is needed —
# EICE proxies SSH to the instance's private IP, and the NAT gateway handles
# all outbound connections.
#
# Teardown: destroyed alongside the rest of the EKS root on terraform destroy.

# ---------------------------------------------------------------------------
# IAM — instance profile
# ---------------------------------------------------------------------------
#
# EICE does not require instance-side IAM permissions for access.
# The only permission needed is eks:DescribeCluster for update-kubeconfig.

resource "aws_iam_role" "bastion" {
  name = "${local.cluster_name}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# EKS read — allows aws eks update-kubeconfig to describe the cluster
resource "aws_iam_role_policy" "bastion_eks" {
  name = "eks-describe"
  role = aws_iam_role.bastion.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEKSDescribe"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.cluster_name}"
      },
      {
        Sid      = "AllowIAMGetRole"
        Effect   = "Allow"
        Action   = "iam:GetRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${local.cluster_name}-*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.cluster_name}-bastion"
  role = aws_iam_role.bastion.name
}

# ---------------------------------------------------------------------------
# EC2 Instance Connect Endpoint (EICE)
# ---------------------------------------------------------------------------
#
# Proxies SSH connections to the bastion over the private IP — no open
# inbound port on the internet, no public key pre-registration required.
# Placed in the public subnet alongside the bastion.

resource "aws_security_group" "eice" {
  name        = "${local.cluster_name}-eice"
  description = "EICE - SSH outbound to bastion"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "eice_egress_ssh" {
  description              = "SSH to bastion"
  type                     = "egress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eice.id
  source_security_group_id = aws_security_group.bastion.id
}

resource "aws_ec2_instance_connect_endpoint" "bastion" {
  subnet_id          = module.vpc.private_subnets[0]
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false
}

# ---------------------------------------------------------------------------
# Bastion security group
# ---------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${local.cluster_name}-bastion"
  description = "Bastion - EICE inbound SSH, HTTPS outbound"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "bastion_ingress_ssh" {
  description              = "SSH from EICE"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.bastion.id
  source_security_group_id = aws_security_group.eice.id
}

resource "aws_security_group_rule" "bastion_egress_https" {
  description       = "HTTPS to internet and VPC endpoints"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.bastion.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# EKS access entry — bastion
# ---------------------------------------------------------------------------
#
# Grants the bastion instance role cluster-admin access so kubectl and helm
# can manage cluster resources. Uses the EKS access entry API (not aws-auth).

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# ---------------------------------------------------------------------------
# Cluster security group rule
# ---------------------------------------------------------------------------
#
# Allows the bastion to reach the EKS private API endpoint.

resource "aws_security_group_rule" "cluster_ingress_bastion" {
  description              = "Bastion to cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = aws_security_group.bastion.id
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
#
# Standard AL2023 AMI — ec2-instance-connect is pre-installed.
# User data installs kubectl and helm so the instance is ready on first boot.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # Require IMDSv2 — token-based metadata requests only. IMDSv1 allows
  # unauthenticated HTTP requests to the metadata endpoint, which is
  # exploitable via SSRF. hop_limit=1 prevents forwarded requests from
  # reaching the metadata service (containers, proxies).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # git
    dnf install -y git

    # clone iss-tracker repo
    git clone https://github.com/scottcrespo/iss-tracker.git /home/ec2-user/iss-tracker

    # kubectl
    curl -Lo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl

    # helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # configure kubeconfig for the cluster
    aws eks update-kubeconfig --name ${local.cluster_name} --region ${local.region}

    # helm repos
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
  EOF

  tags = {
    Name = "${local.cluster_name}-bastion"
  }
}