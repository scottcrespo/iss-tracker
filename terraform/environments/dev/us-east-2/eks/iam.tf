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
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/iss-tracker-*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IRSA — AWS Load Balancer Controller
# ---------------------------------------------------------------------------
#
# The LB Controller runs as a Deployment in kube-system and manages ALBs on
# behalf of Ingress resources. It needs IAM permissions to create, update,
# and delete load balancers, target groups, listeners, and related resources.
#
# Trust is scoped to the exact service account the controller runs as
# (kube-system/aws-load-balancer-controller) using StringEquals — not
# StringLike — so no other service account can assume this role.
#
# The permission policy is the AWS reference policy for the LB Controller.
# Source: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

resource "aws_iam_role" "lb_controller" {
  name = "iss-tracker-eks-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLBControllerServiceAccount"
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lb_controller" {
  #checkov:skip=CKV_AWS_290:AWS reference policy for the Load Balancer Controller — published by kubernetes-sigs, minimum required permissions for ALB provisioning. Cannot be scoped further without breaking controller functionality.
  #checkov:skip=CKV_AWS_355:AWS reference policy for the Load Balancer Controller requires wildcard resources for several actions (e.g. elasticloadbalancing:Describe*, ec2:Describe*) because the controller must enumerate resources it does not yet know the ARN of. Restricting these would break ALB discovery and provisioning.

  name = "aws-load-balancer-controller"
  role = aws_iam_role.lb_controller.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowCreateServiceLinkedRole"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowDescribeResources"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCognitoAndACM"
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEC2SecurityGroupManagement"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowEC2SecurityGroupTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestedRegion" = "false"
          }
        }
      },
      {
        Sid    = "AllowEC2SecurityGroupRuleManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "false"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "AllowEC2SecurityGroupModification"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "AllowELBManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "AllowELBListenerAndRuleManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowELBTagManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "AllowELBListenerTagManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
        ]
      },
      {
        Sid    = "AllowELBAttributeManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Sid    = "AllowELBTargetManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Sid    = "AllowELBListenerRuleManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
        ]
        Resource = "*"
      },
    ]
  })
}