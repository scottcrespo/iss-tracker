output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "ARN of the IAM role"
  value       = aws_iam_role.this.arn
  sensitive   = true
}

output "group_name" {
  description = "Name of the IAM group whose members may assume this role"
  value       = aws_iam_group.this.name
}