# ---------------------------------------------------------------------------
# EKS Cluster Role
# ---------------------------------------------------------------------------
#
# Assumed by the EKS control plane to manage AWS resources on behalf of the
# cluster — creating cross-account ENIs, describing EC2 resources, managing
# load balancer targets, etc.
#
# AmazonEKSClusterPolicy is the AWS-managed policy that grants exactly the
# permissions the control plane needs. No inline policy required.

resource "aws_iam_role" "eks_cluster" {
  name = "iss-tracker-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEKSControlPlane"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Fargate Pod Execution Role
# ---------------------------------------------------------------------------
#
# Assumed by the Fargate infrastructure (not the pod itself) when launching
# a pod. Used for two things only:
#   1. Pulling container images from ECR
#   2. Shipping container logs to CloudWatch via the built-in log router
#
# This is distinct from IRSA roles — the execution role is about running the
# pod, not what the pod's application code is allowed to do in AWS.
#
# AmazonEKSFargatePodExecutionRolePolicy grants the minimum ECR and
# CloudWatch Logs permissions required. No inline policy needed.

resource "aws_iam_role" "eks_fargate" {
  name = "iss-tracker-eks-fargate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFargatePodExecution"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_fargate" {
  role       = aws_iam_role.eks_fargate.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}