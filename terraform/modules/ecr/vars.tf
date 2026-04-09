variable "repository_name" {
  description = "Name of the ECR repository"
  type        = string
}

variable "untagged_image_retention_days" {
  description = "Number of days to retain untagged images before expiring them"
  type        = number
  default     = 7
}

variable "max_tagged_images" {
  description = "Maximum number of tagged images to retain in the repository"
  type        = number
  default     = 20
}

variable "encryption_type" {
  description = "Encryption type for the repository. AES256 uses the default AWS-managed key. KMS requires kms_key_arn to be set."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS"
  }
}

variable "kms_key_arn" {
  description = "ARN of the KMS key to use when encryption_type is KMS. Ignored for AES256."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to the repository"
  type        = map(string)
  default     = {}
}