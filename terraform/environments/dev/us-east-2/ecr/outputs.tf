output "api_repository_url" {
  description = "URL of the iss-api ECR repository"
  value       = module.ecr_api.repository_url
}

output "poller_repository_url" {
  description = "URL of the iss-poller ECR repository"
  value       = module.ecr_poller.repository_url
}