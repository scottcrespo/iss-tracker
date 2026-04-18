# ---------------------------------------------------------------------------
# KMS — EKS secrets encryption
# ---------------------------------------------------------------------------
#
# Enables envelope encryption for Kubernetes secrets at rest. The EKS control
# plane calls this key when writing secrets to etcd and when reading them back.
# Without this, secrets in etcd are encoded (base64) but not encrypted at the
# application layer. Note that EKS already encrypts etcd storage at the
# infrastructure layer via AWS-managed EBS encryption — this adds a second
# layer using a key owned by this account.
#
# Key rotation is enabled — AWS automatically creates a new key version
# annually and re-encrypts data keys. No manual rotation steps required.

resource "aws_kms_key" "eks_secrets" {
  description             = "EKS secrets encryption - ${local.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Account root has full access so IAM can delegate key permissions.
        # Required by AWS — a KMS key with no root access cannot be recovered.
        Sid    = "AllowAccountRootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # EKS control plane (running as the cluster role) encrypts and decrypts
        # secrets. CreateGrant allows the control plane to pass the key to
        # worker nodes for decryption without granting full key access.
        Sid    = "AllowEKSClusterRoleEncryption"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.eks_cluster.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}
