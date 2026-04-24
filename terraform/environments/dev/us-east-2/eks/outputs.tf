output "fargate_private_sg_id" {
  description = "SG ID to inject into k8s/sgp-iss-tracker.yaml SecurityGroupPolicy"
  value       = aws_security_group.fargate_private.id
}

# ---------------------------------------------------------------------------
# Outputs consumed by the bastion root via terraform_remote_state.
# Kept thin - only the coupled values that the bastion root cannot
# discover by tag or name lookup on its own.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID. Consumed by the bastion root."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Consumed by the bastion root for bastion and EICE placement."
  value       = module.vpc.private_subnets
}

output "cluster_name" {
  description = "EKS cluster name. Consumed by the bastion root for access entry and user_data update-kubeconfig."
  value       = module.eks.cluster_name
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID. Consumed by the bastion root to add a TCP/443 ingress rule sourced from the bastion SG."
  value       = module.eks.cluster_security_group_id
}