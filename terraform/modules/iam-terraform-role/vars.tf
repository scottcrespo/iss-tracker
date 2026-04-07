variable "account_id" {
    description = <<-EOT
        AWS Account ID. This is used to establish the trust Principal
        in determining who/what can assume the role
    EOT
    type = string
    sensitive = true
}

variable "environment" {
    description = "The name of the environment to provision the resources for"
    type = string
}

variable "permission_boundary_allowed_managed_policies" {
    description = <<-EOT
        List of AWS ARNs of managed policies that may be attached to roles
        provisioned by the terraform role
    EOT
    type = list
    default = []
}

variable "project_scope_limit_prefix" {
    description = <<-EOT
        This variable is used to limit the scope of PROJECT resources the role can
        manipulate, or other roles created by it. This is done by adding the project
        name as a prefix to IAM resource constraints in IAM policies.
    EOT
    type = string
}

variable "region" {
    description = "AWS region. This is used to scope resources managed by the terraform role, or other roles it provisions."
    type = string
}

variable "tags" {
    description = "Tags to attach to resources provisioned by this module"
    type = map
    default = {}
}

variable "terraform_role_allowed_managed_policies" {
    description = "List of managed AWS policy ARNs that may be attached to the terraform role"
    default = []
}