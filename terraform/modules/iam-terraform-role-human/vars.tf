variable "role_name" {
  description = "Name of the IAM role"
  type        = string
}

variable "account_id" {
  description = "AWS account ID. Used to construct the trust policy principal ARN. Marked sensitive."
  type        = string
  sensitive   = true
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