output "role_name" {
  description = "Name of the terraform role"
  value       = aws_iam_role.terraform_role.name
}

output "role_arn" {
  description = "ARN of the terraform role"
  value       = aws_iam_role.terraform_role.arn
  sensitive   = true
}

output "permission_boundary_arn" {
  description = "ARN of the permission boundary policy"
  value       = aws_iam_policy.permission_boundary.arn
  sensitive   = true
}

output "group_name" {
  description = "Name of the IAM group permitted to assume the terraform role"
  value       = var.trust_type == "iam" ? aws_iam_group.terraform_group[0].name : ""
}