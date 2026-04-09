resource "aws_iam_group" "terraform_group" {
  # only create group when trust_type == iam
  count = var.trust_type == "iam" ? 1 : 0
  name  = "${var.role_name}-group"
}

resource "aws_iam_group_policy" "terraform_group_policy_inline" {
  # only create policy when trust_type == iam
  count = var.trust_type == "iam" ? 1 : 0
  name  = "terraform-${var.environment}-group-policy"
  group = aws_iam_group.terraform_group[0].name

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