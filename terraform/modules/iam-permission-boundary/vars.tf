variable "name" {
  description = "Name of the permission boundary policy"
  type        = string
}

variable "policy_json" {
  description = "JSON policy document defining the maximum permissions any role with this boundary can exercise"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the boundary policy"
  type        = map(string)
  default     = {}
}
