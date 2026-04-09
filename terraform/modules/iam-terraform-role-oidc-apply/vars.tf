variable "role_name" {
  description = "Name of the IAM role"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC identity provider"
  type        = string
}

variable "oidc_subjects" {
  description = "List of OIDC subject claim values permitted to assume this role (e.g. repo:org/repo:ref:refs/heads/main)"
  type        = list(string)
}

variable "permission_boundary_arn" {
  description = "ARN of the permission boundary policy to attach to the role"
  type        = string
  sensitive   = true
}

variable "managed_policy_arns" {
  description = "List of AWS managed policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional JSON policy document to attach as an inline policy. Define the document with jsonencode() in the calling root."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}