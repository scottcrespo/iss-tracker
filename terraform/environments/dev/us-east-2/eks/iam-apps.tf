# ---------------------------------------------------------------------------
# IRSA — API
# ---------------------------------------------------------------------------
#
# Assumed by the API pod via Kubernetes service account annotation. Grants
# read/write access to the ISS DynamoDB table only.
#
# Trust is scoped to the exact service account (default/api) using
# StringEquals — the same OIDC federation pattern as the LB Controller but
# pointed at the application namespace and service account name.

resource "aws_iam_role" "irsa_api" {
  name = "iss-tracker-eks-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAPIServiceAccount"
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:iss-tracker:api"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "irsa_api" {
  name = "dynamodb-access"
  role = aws_iam_role.irsa_api.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/iss-tracker-*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IRSA — Poller

# ---------------------------------------------------------------------------
#
# Assumed by the Poller CronJob pod. Grants write-only access to the ISS
# DynamoDB table — the poller only records position data, it never reads it.
#
# Scoped to the iss-tracker namespace and poller service account, same
# pattern as the API role.

resource "aws_iam_role" "irsa_poller" {
  name = "iss-tracker-eks-poller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPollerServiceAccount"
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:iss-tracker:poller"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "irsa_poller" {
  name = "dynamodb-write"
  role = aws_iam_role.irsa_poller.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDynamoDBWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/iss-tracker-*"
      }
    ]
  })
}