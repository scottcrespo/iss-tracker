output "boundary_arn" {
  description = "ARN of the permission boundary policy"
  value       = aws_iam_policy.boundary.arn
  sensitive   = true
}

output "boundary_name" {
  description = "Name of the permission boundary policy"
  value       = aws_iam_policy.boundary.name
}