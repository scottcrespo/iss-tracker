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
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
  name_prefix  = "iss-tracker"
  boundary_arn = module.boundary.boundary_arn

  # Permission boundary policy — caps the maximum permissions any role provisioned
  # by the human Terraform operator can exercise. Scoped to project-prefixed resources.
  # IAM actions are denied unconditionally to prevent escalation through provisioned roles.
  boundary_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEKS"
        Effect   = "Allow"
        Action   = "eks:*"
        Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.name_prefix}-*"
      },
      {
        Sid      = "AllowDynamoDB"
        Effect   = "Allow"
        Action   = "dynamodb:*"
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.name_prefix}-*"
      },
      {
        Sid      = "AllowECRAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "AllowECRRepositoryAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${local.name_prefix}-*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/${local.name_prefix}/*:*"
      },
      {
        # Allows application roles provisioned by this operator (e.g. the EKS
        # cluster role) to use KMS keys. Does not grant key management — only
        # the encrypt/decrypt/grant operations application workloads need.
        Sid    = "AllowKMSKeyUsage"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants",
        ]
        Resource = "arn:aws:kms:${local.region}:${local.account_id}:key/*"
      },
      {
        Sid      = "DenyIAM"
        Effect   = "Deny"
        Action   = "iam:*"
        Resource = "*"
      },
    ]
  })

  # Inline policy for the human Terraform role — grants scoped IAM write access to
  # provision application workload roles. All mutating actions require the permissions
  # boundary to be attached, preventing privilege escalation via provisioned roles.
  human_inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoleManagementWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.boundary_arn
          }
        }
      },
      {
        Sid    = "AllowPolicyAttachmentScopedToProject"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
        Condition = {
          ArnLike = {
            "iam:PolicyARN" = "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-*"
          }
        }
      },
      {
        Sid    = "AllowAttachAWSManagedPolicies"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
              "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
            ]
          }
        }
      },
      {
        Sid      = "AllowPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
      },
      {
        Sid      = "DenyPermissionsBoundaryDeletion"
        Effect   = "Deny"
        Action   = "iam:DeleteRolePermissionsBoundary"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.boundary_arn
          }
        }
      },
      {
        Sid    = "DenyPolicyChange"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
        ]
        Resource = local.boundary_arn
      },
      {
        # CreateKey and listing actions require Resource: "*" — AWS does not
        # support resource-level restrictions on key creation.
        Sid    = "AllowKMSKeyCreationAndListing"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:ListKeys",
          "kms:ListAliases",
        ]
        Resource = "*"
      },
      {
        # Key management scoped to this account. Aliases further scoped to the
        # project prefix to prevent accidental modification of unrelated keys.
        Sid    = "AllowKMSKeyManagement"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:EnableKeyRotation",
          "kms:DisableKeyRotation",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateKeyDescription",
          "kms:CreateAlias",
          "kms:UpdateAlias",
          "kms:DeleteAlias",
        ]
        Resource = [
          "arn:aws:kms:${local.region}:${local.account_id}:key/*",
          "arn:aws:kms:${local.region}:${local.account_id}:alias/${local.name_prefix}-*",
        ]
      },
    ]
  })
}

module "boundary" {
  source = "../../../../../modules/iam-permission-boundary"

  name        = "iss-tracker-dev-boundary"
  policy_json = local.boundary_policy_json
  tags        = { environment = "dev" }
}

module "terraform_role_human" {
  source = "../../../../../modules/iam-terraform-role-human"

  role_name               = "terraform-dev-human"
  account_id              = sensitive(local.account_id)
  permission_boundary_arn = local.boundary_arn

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccessV2",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess",
  ]

  inline_policy_json = local.human_inline_policy_json

  tags = { environment = "dev" }
}