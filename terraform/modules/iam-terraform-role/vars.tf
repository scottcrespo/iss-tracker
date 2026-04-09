variable "account_id" {
  description = <<-EOT
        AWS Account ID. This is used to establish the trust Principal
        in determining who/what can assume the role
    EOT
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "The name of the environment to provision the resources for"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of OIDC provider if allowing federated access to role"
  type        = string
  default     = ""
}

variable "oidc_subjects" {
  description = "List of OIDC subjects to allow to assume the role"
  type        = list(string)
  default     = []
}

variable "permission_boundary_allowed_managed_policies" {
  description = <<-EOT
        List of AWS ARNs of managed policies that may be attached to roles
        provisioned by the terraform role
    EOT
  type        = list(any)
  default     = []
}

variable "project_scope_limit_prefix" {
  description = <<-EOT
        This variable is used to limit the scope of PROJECT resources the role can
        manipulate, or other roles created by it. This is done by adding the project
        name as a prefix to IAM resource constraints in IAM policies.
    EOT
  type        = string
}

variable "region" {
  description = "AWS region. This is used to scope resources managed by the terraform role, or other roles it provisions."
  type        = string
}

variable "role_name" {
  description = "Name of the role to be provisioned"
  type        = string
}

variable "tags" {
  description = "Tags to attach to resources provisioned by this module"
  type        = map(any)
  default     = {}
}

variable "terraform_role_allowed_managed_policies" {
  description = "List of managed AWS policy ARNs that may be attached to the terraform role"
  default     = []
}

variable "trust_type" {
  description = "Chose between iam or oidc"
  type        = string
  default     = "iam"
}

variable "role_type" {
  description = "Controls whether the role gets full IAM write permissions (full) or plan-only read permissions (plan). Use 'plan' for CI roles that only run terraform plan."
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "plan"], var.role_type)
    error_message = "role_type must be 'full' or 'plan'"
  }
}