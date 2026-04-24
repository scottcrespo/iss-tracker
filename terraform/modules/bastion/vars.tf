variable "name_prefix" {
  description = "Prefix applied to all resource names (e.g., \"iss-tracker-eks-dev\")."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy bastion resources into."
  type        = string
}

variable "bastion_subnet_id" {
  description = "Private subnet ID for the bastion EC2 instance."
  type        = string
}

variable "eice_subnet_id" {
  description = "Subnet ID for the EC2 Instance Connect Endpoint. Typically the same private subnet as the bastion."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Used for the access entry and templated into user_data for aws eks update-kubeconfig."
  type        = string
}

variable "cluster_security_group_id" {
  description = "EKS cluster security group ID. A rule is added granting the bastion SG ingress to this SG on TCP/443 (cluster API)."
  type        = string
}

variable "region" {
  description = "AWS region. Templated into user_data for aws eks update-kubeconfig."
  type        = string
}

variable "iam_policies" {
  description = "Map of inline policy name to JSON policy document string. Caller-defined per the project IAM Governance rule - no module in this codebase defines what an identity is allowed to do. At minimum, callers should supply a policy granting eks:DescribeCluster so kubectl can fetch cluster details."
  type        = map(string)
  default     = {}
}

variable "repo_url" {
  description = "Optional Git repository URL to clone into the bastion's ec2-user home directory on first boot. If null, the clone step is skipped."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the bastion."
  type        = string
  default     = "t3.micro"
}

variable "ami_name_filter" {
  description = "Glob pattern(s) matched against the AMI name filter. Default selects the latest Amazon Linux 2023 x86_64 AMI. Override to use Ubuntu, Bottlerocket, or a custom AMI - note that user_data assumes dnf, /home/ec2-user, and ec2-instance-connect pre-installed; non-AL2023 AMIs will require corresponding user_data changes."
  type        = list(string)
  default     = ["al2023-ami-2023.*-kernel-*-x86_64"]
}

variable "ami_owners" {
  description = "AMI owner account IDs or aliases matched against the AMI lookup. Default is [\"amazon\"] for Amazon-published AMIs. Override with an AWS account ID when using a custom AMI."
  type        = list(string)
  default     = ["amazon"]
}

variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Security group inputs
# ---------------------------------------------------------------------------
#
# Each SG the module depends on has two coordinated inputs:
#
#   1. create_<name>_security_group (bool, default true)
#        When true, the module creates the SG and its pre-baked rules.
#   2. <name>_security_group_id (string, default null)
#        When the create flag is false, the caller supplies an external
#        SG ID. Module-internal references resolve through a local that
#        returns the module-managed SG ID or the external input, so
#        downstream resources do not care which path provided it.
#
# Exactly one path must be used per SG, enforced by variable validation.
# Cross-referencing rules (bastion ingress from EICE, EICE egress to
# bastion, cluster ingress from bastion) remain internal and always
# function correctly because they consume the locals, not the raw
# resources.

variable "create_bastion_security_group" {
  description = "Whether the module creates the bastion security group and its pre-baked rules (SSH ingress from EICE, HTTPS egress). Default true. When false, bastion_security_group_id must be supplied and the caller owns the SG and its rules."
  type        = bool
  default     = true
}

variable "bastion_security_group_id" {
  description = "ID of an externally-managed bastion security group. Required when create_bastion_security_group is false; must be null when it is true. The module attaches the bastion instance to this SG and references it from the cluster ingress rule and the EICE egress rule."
  type        = string
  default     = null

  validation {
    condition     = !(var.create_bastion_security_group == false && var.bastion_security_group_id == null)
    error_message = "When create_bastion_security_group is false, bastion_security_group_id must be provided."
  }

  validation {
    condition     = !(var.create_bastion_security_group == true && var.bastion_security_group_id != null)
    error_message = "When create_bastion_security_group is true, bastion_security_group_id must be null - the module manages the SG."
  }
}

variable "create_eice_security_group" {
  description = "Whether the module creates the EICE security group and its pre-baked rule (SSH egress to the bastion SG). Default true. When false, eice_security_group_id must be supplied and the caller owns the SG and its rules."
  type        = bool
  default     = true
}

variable "eice_security_group_id" {
  description = "ID of an externally-managed EICE security group. Required when create_eice_security_group is false; must be null when it is true. The module attaches the EICE endpoint to this SG and references it from the bastion ingress rule."
  type        = string
  default     = null

  validation {
    condition     = !(var.create_eice_security_group == false && var.eice_security_group_id == null)
    error_message = "When create_eice_security_group is false, eice_security_group_id must be provided."
  }

  validation {
    condition     = !(var.create_eice_security_group == true && var.eice_security_group_id != null)
    error_message = "When create_eice_security_group is true, eice_security_group_id must be null - the module manages the SG."
  }
}