# ---------------------------------------------------------------------------
# VPC Flow Logs
# ---------------------------------------------------------------------------
#
# IAM role trust policy and permission policy are caller-defined.
# The role ARN is injected into the flow-log module, which handles
# log group creation and the aws_flow_log resource.

resource "aws_iam_role" "flow_logs" {
  name = "${local.cluster_name}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFlowLogsService"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "flow-logs-cloudwatch"
  role = aws_iam_role.flow_logs.name
  # we want to restrict role's permission to cluster
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/vpc/flow-logs/${local.cluster_name}:*"
      }
    ]
  })
}

module "vpc_flow_log" {
  source  = "terraform-aws-modules/vpc/aws//modules/flow-log"
  version = "6.6.1"

  vpc_id                                 = module.vpc.vpc_id
  create_iam_role                        = false
  cloudwatch_log_group_name              = "/aws/vpc/flow-logs/${local.cluster_name}"
  cloudwatch_log_group_retention_in_days = 30
  iam_role_arn                           = aws_iam_role.flow_logs.arn
  traffic_type                           = "ALL"
}