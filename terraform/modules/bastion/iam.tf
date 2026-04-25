# ---------------------------------------------------------------------------
# Bastion IAM role + instance profile
# ---------------------------------------------------------------------------
#
# Trust policy is structural (EC2 service principal) and defined here. All
# permission policy content is supplied by the caller via var.iam_policies,
# per the project IAM Governance rule.

resource "aws_iam_role" "bastion" {
  name = "${var.name_prefix}-bastion"

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

  tags = var.tags
}

resource "aws_iam_role_policy" "bastion" {
  for_each = var.iam_policies

  name   = each.key
  role   = aws_iam_role.bastion.name
  policy = each.value
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-bastion"
  role = aws_iam_role.bastion.name

  tags = var.tags
}