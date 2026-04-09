resource "aws_iam_role" "this" {
  name                 = var.role_name
  permissions_boundary = var.permission_boundary_arn
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRootAssumption"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy_json != null ? 1 : 0
  name   = "inline-${var.role_name}"
  role   = aws_iam_role.this.name
  policy = var.inline_policy_json
}

resource "aws_iam_group" "this" {
  name = "${var.role_name}-users"
}

resource "aws_iam_group_policy" "assume_role" {
  name  = "assume-${var.role_name}"
  group = aws_iam_group.this.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowAssumeRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.this.arn
      }
    ]
  })
}