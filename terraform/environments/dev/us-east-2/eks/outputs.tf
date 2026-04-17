output "fargate_private_sg_id" {
  description = "SG ID to inject into k8s/sgp-iss-tracker.yaml SecurityGroupPolicy"
  value       = aws_security_group.fargate_private.id
}