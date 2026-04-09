resource "aws_iam_policy" "boundary" {
  name   = var.name
  policy = var.policy_json
  tags   = var.tags
}