resource "aws_iam_policy" "permission_boundary" {
    name = "terraform-${var.environment}-boundary-for-provisioned-roles"

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Sid      = "AllowEKS"
                Effect   = "Allow"
                Action   = "eks:*"
                Resource = "arn:aws:eks:${var.region}:${var.account_id}:cluster/${local.resource_scope_limit}"
            },
            {
                Sid      = "AllowDynamoDB"
                Effect   = "Allow"
                Action   = "dynamodb:*"
                Resource = "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${local.resource_scope_limit}"
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
                    "ecr:BatchCheckLayerAvailability"
                ]
                Resource = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${local.resource_scope_limit}"
            },
            {
                Sid    = "AllowCloudWatchLogs"
                Effect = "Allow"
                Action = [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents",
                    "logs:DescribeLogGroups",
                    "logs:DescribeLogStreams"
                ]
                Resource = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/${var.project_scope_limit_prefix}/*:*"
            },
            {
                Sid      = "DenyIAM"
                Effect   = "Deny"
                Action   = "iam:*"
                Resource = "*"
            }
        ]
    })
}