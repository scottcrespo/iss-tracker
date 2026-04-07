resource "aws_iam_group" "terraform_group" {
  name = "terraform-${var.environment}"
}

resource "aws_iam_group_policy" "terraform_group_policy_inline" {
  name  = "terraform-${var.environment}-group-policy"
  group = aws_iam_group.terraform_group.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowAssumeTerraformRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "${aws_iam_role.terraform_role.arn}"
    }]
  })
}