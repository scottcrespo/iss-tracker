output "iss_tracker_sg_id" {
  description = "SG ID to inject into k8s/iss-tracker/manifests/bootstrap/sgp-iss-tracker.yaml"
  value       = aws_security_group.iss_tracker.id
}

output "argocd_sg_id" {
  description = "SG ID to inject into k8s/argocd/manifests/bootstrap/sgp-argocd.yaml"
  value       = aws_security_group.argocd.id
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

output "eso_irsa_role_arn" {
  description = "ESO IRSA role ARN. Injected into the ESO Helm install as serviceAccount.annotations."
  value       = aws_iam_role.eso.arn
}

output "cluster_security_group_id" {
  description = "EKS primary (EKS-managed) cluster SG ID. Consumed by the bastion root to add a TCP/443 ingress rule sourced from the bastion SG. Uses the primary SG because the EKS control plane uses this SG for all connections to pods and to accept inbound API traffic."
  value       = local.eks_primary_sg_id
}