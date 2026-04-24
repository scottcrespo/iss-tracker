output "instance_id" {
  description = "EC2 instance ID of the bastion. Use with `aws ec2-instance-connect ssh --instance-id ...`."
  value       = module.bastion.instance_id
}

output "bastion_role_arn" {
  description = "ARN of the bastion IAM role. Useful for cross-referencing in other roots or for audit."
  value       = module.bastion.bastion_role_arn
}

output "bastion_security_group_id" {
  description = "ID of the bastion security group."
  value       = module.bastion.bastion_security_group_id
}

output "eice_security_group_id" {
  description = "ID of the EICE security group."
  value       = module.bastion.eice_security_group_id
}