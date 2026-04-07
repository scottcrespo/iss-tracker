resource "aws_iam_role" "terraform_role" {
    name = "terraform-${var.environment}"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Sid    = "TrustStatement"
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    AWS = "arn:aws:iam::${var.account_id}:root"
                }
            }
        ]
    })
    tags = var.tags
}

resource "aws_iam_role_policy_attachment" "terraform_role_managed_policies" {
    for_each   = toset(var.terraform_role_allowed_managed_policies)
    role       = aws_iam_role.terraform_role.name
    policy_arn = each.value
}

resource "aws_iam_role_policy" "terraform_role_inline" {
    name = "inline-policy-for-terraform-${var.environment}-role"
    role = aws_iam_role.terraform_role.name

    policy = jsonencode({
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
                    "iam:RemoveRoleFromInstanceProfile"
                ]
                Resource = "arn:aws:iam::${var.account_id}:role/${local.resource_scope_limit}"
                Condition = {
                    StringEquals = {
                        "iam:PermissionsBoundary" = aws_iam_policy.permission_boundary.arn
                    }
                }
            },
            {
                Sid    = "AllowPolicyAttachmentScopedToProject"
                Effect = "Allow"
                Action = [
                    "iam:AttachRolePolicy",
                    "iam:DetachRolePolicy"
                ]
                Resource = "arn:aws:iam::${var.account_id}:role/${local.resource_scope_limit}"
                Condition = {
                    ArnLike = {
                        "iam:PolicyARN" = "arn:aws:iam::${var.account_id}:policy/${local.resource_scope_limit}"
                    }
                }
            },
            {
                Sid    = "AllowAttachAWSManagedPolicies"
                Effect = "Allow"
                Action = [
                    "iam:AttachRolePolicy",
                    "iam:DetachRolePolicy"
                ]
                Resource = "arn:aws:iam::${var.account_id}:role/${local.resource_scope_limit}"
                Condition = {
                    ArnEquals = {
                        "iam:PolicyARN" = var.permission_boundary_allowed_managed_policies
                    }
                }
            },
            {
                Sid      = "AllowPassRole"
                Effect   = "Allow"
                Action   = "iam:PassRole"
                Resource = "arn:aws:iam::${var.account_id}:role/${local.resource_scope_limit}"
            },
            {
                Sid      = "DenyPermissionsBoundaryDeletion"
                Effect   = "Deny"
                Action   = "iam:DeleteRolePermissionsBoundary"
                Resource = "*"
                Condition = {
                    StringEquals = {
                        "iam:PermissionsBoundary" = aws_iam_policy.permission_boundary.arn
                    }
                }
            },
            {
                Sid    = "DenyPolicyChange"
                Effect = "Deny"
                Action = [
                    "iam:CreatePolicyVersion",
                    "iam:DeletePolicyVersion",
                    "iam:SetDefaultPolicyVersion"
                ]
                Resource = aws_iam_policy.permission_boundary.arn
            }
        ]
    })
}