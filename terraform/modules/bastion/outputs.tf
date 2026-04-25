output "bastion_role_arn" {
  description = "ARN of the bastion IAM role. Useful for cross-account trust conditions or injecting into downstream IAM policies."
  value       = aws_iam_role.bastion.arn
}

output "bastion_role_name" {
  description = "Name of the bastion IAM role."
  value       = aws_iam_role.bastion.name
}

output "instance_id" {
  description = "EC2 instance ID of the bastion. Use with `aws ec2-instance-connect ssh --instance-id ...`."
  value       = aws_instance.bastion.id
}

output "bastion_security_group_id" {
  description = "ID of the bastion security group - whether created by the module or supplied as an externally-managed SG."
  value       = local.bastion_sg_id
}

output "eice_security_group_id" {
  description = "ID of the EICE security group - whether created by the module or supplied as an externally-managed SG."
  value       = local.eice_sg_id
}

output "user_data_rendered" {
  description = "Rendered user_data script. Exposed for test assertions and operational debugging - the aws_instance user_data attribute stores a hash, not the plaintext."
  value       = local.user_data_rendered
}