# Tests for the bastion module.
#
# Uses mock_provider "aws" so no AWS credentials or live resources are
# required. Run from the module directory with: terraform test
#
# Test categories:
#   - IAM governance: injected policies are attached unchanged and no
#     additional policies are added (content + count equality)
#   - Security group toggles: SGs and their bundled rules are created or
#     skipped together
#   - AMI lookup: default filter is AL2023; overrides work
#   - Instance hardening: IMDSv2 required, encrypted root volume
#   - user_data rendering: template variables substituted correctly;
#     repo_url = null skips the git clone line
#   - EKS access entry: created for the bastion role with cluster scope
#   - Cluster SG ingress: bastion-to-cluster TCP/443 rule is created

mock_provider "aws" {}

variables {
  name_prefix               = "test-bastion"
  vpc_id                    = "vpc-0123456789abcdef0"
  bastion_subnet_id         = "subnet-0123456789abcdef0"
  eice_subnet_id            = "subnet-0123456789abcdef0"
  cluster_name              = "test-cluster"
  cluster_security_group_id = "sg-0123456789abcdef0"
  region                    = "us-east-2"
  repo_url                  = "https://github.com/example/repo.git"
}

# ---------------------------------------------------------------------------
# IAM governance verification
# ---------------------------------------------------------------------------
#
# Verifies the project IAM Governance rule at the module level: policy
# content flows through unchanged, and the module contributes no policy of
# its own.

run "iam_policy_content_unchanged" {
  command = plan

  variables {
    iam_policies = {
      eks_describe = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "EksDescribe"
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster"]
          Resource = "arn:aws:eks:us-east-2:123456789012:cluster/test-cluster"
        }]
      })
      s3_read = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "S3Read"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "arn:aws:s3:::example-bucket/*"
        }]
      })
    }
  }

  # Content equality: attached policy equals caller's input, byte-for-byte
  # (after jsondecode normalization for whitespace/ordering).
  assert {
    condition = jsondecode(aws_iam_role_policy.bastion["eks_describe"].policy) == jsondecode(var.iam_policies["eks_describe"])
    error_message = "Module mutated the eks_describe policy document - caller ownership violated"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.bastion["s3_read"].policy) == jsondecode(var.iam_policies["s3_read"])
    error_message = "Module mutated the s3_read policy document - caller ownership violated"
  }

  # Count equality: one attached policy per input entry, no extras.
  assert {
    condition     = length(aws_iam_role_policy.bastion) == length(var.iam_policies)
    error_message = "Module attached a different number of policies than the caller supplied"
  }
}

run "iam_no_policies_when_none_supplied" {
  command = plan

  variables {
    iam_policies = {}
  }

  # With empty input, no policy attachments exist. Proves the module does
  # not inject any policy of its own.
  assert {
    condition     = length(aws_iam_role_policy.bastion) == 0
    error_message = "Module attached a policy when caller supplied none"
  }
}

# ---------------------------------------------------------------------------
# Security group toggles
# ---------------------------------------------------------------------------

run "bastion_sg_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_security_group.bastion) == 1
    error_message = "Bastion SG should be created by default"
  }

  assert {
    condition     = length(aws_security_group_rule.bastion_ingress_ssh_from_eice) == 1
    error_message = "Bastion SG ingress rule should be created with the SG"
  }

  assert {
    condition     = length(aws_security_group_rule.bastion_egress_https) == 1
    error_message = "Bastion SG egress rule should be created with the SG"
  }

  # Cluster ingress rule is always created - it sources from the bastion
  # SG via local, which resolves regardless of who manages the SG.
  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.type == "ingress"
    error_message = "Cluster ingress rule should be created on the default path"
  }
}

run "eice_sg_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_security_group.eice) == 1
    error_message = "EICE SG should be created by default"
  }

  assert {
    condition     = length(aws_security_group_rule.eice_egress_ssh_to_bastion) == 1
    error_message = "EICE SG egress rule should be created with the SG"
  }
}

# ---------------------------------------------------------------------------
# External SG path
# ---------------------------------------------------------------------------
#
# When a create flag is false and the corresponding <name>_security_group_id
# input is supplied, the module skips the SG and its bundled rules, and
# downstream resources consume the external ID via the local. Verifies the
# full pattern: module-managed resources are skipped, the local resolves
# to the external input, and always-created resources (cluster ingress
# rule, EICE endpoint, bastion instance) still plan.

run "bastion_sg_externally_managed" {
  command = plan

  variables {
    create_bastion_security_group = false
    bastion_security_group_id     = "sg-externalbastion0000"
  }

  assert {
    condition     = length(aws_security_group.bastion) == 0
    error_message = "Bastion SG should be skipped when create flag is false"
  }

  assert {
    condition     = length(aws_security_group_rule.bastion_ingress_ssh_from_eice) == 0
    error_message = "Bastion SG rules should be skipped with the SG"
  }

  # local.bastion_sg_id resolves to the external input - verified via the
  # cluster ingress rule, which always exists and sources from the local.
  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.source_security_group_id == "sg-externalbastion0000"
    error_message = "Cluster ingress rule should source from the externally-supplied bastion SG"
  }

  assert {
    condition     = output.bastion_security_group_id == "sg-externalbastion0000"
    error_message = "Output should return the externally-supplied SG ID"
  }

  # EICE SG is still module-managed; its egress rule sources from the
  # external bastion SG through the local.
  assert {
    condition     = aws_security_group_rule.eice_egress_ssh_to_bastion[0].source_security_group_id == "sg-externalbastion0000"
    error_message = "EICE egress rule should source from the external bastion SG via the local"
  }
}

run "eice_sg_externally_managed" {
  command = plan

  variables {
    create_eice_security_group = false
    eice_security_group_id     = "sg-externaleice00000000"
  }

  assert {
    condition     = length(aws_security_group.eice) == 0
    error_message = "EICE SG should be skipped when create flag is false"
  }

  assert {
    condition     = length(aws_security_group_rule.eice_egress_ssh_to_bastion) == 0
    error_message = "EICE SG rules should be skipped with the SG"
  }

  # EICE endpoint consumes the external SG ID via the local.
  assert {
    condition     = aws_ec2_instance_connect_endpoint.bastion.security_group_ids == toset(["sg-externaleice00000000"])
    error_message = "EICE endpoint should attach to the externally-supplied eice SG"
  }

  # Bastion ingress rule (module-managed) sources from the external eice SG.
  assert {
    condition     = aws_security_group_rule.bastion_ingress_ssh_from_eice[0].source_security_group_id == "sg-externaleice00000000"
    error_message = "Bastion ingress rule should source from the external eice SG via the local"
  }

  assert {
    condition     = output.eice_security_group_id == "sg-externaleice00000000"
    error_message = "Output should return the externally-supplied SG ID"
  }
}

run "both_sgs_externally_managed" {
  command = plan

  variables {
    create_bastion_security_group = false
    bastion_security_group_id     = "sg-externalbastion0000"
    create_eice_security_group    = false
    eice_security_group_id        = "sg-externaleice00000000"
  }

  assert {
    condition     = length(aws_security_group.bastion) == 0 && length(aws_security_group.eice) == 0
    error_message = "Both SGs should be skipped when both create flags are false"
  }

  # Instance, EICE endpoint, cluster ingress rule all still plan.
  assert {
    condition     = aws_instance.bastion.vpc_security_group_ids == toset(["sg-externalbastion0000"])
    error_message = "Bastion instance should attach to the external bastion SG"
  }

  assert {
    condition     = aws_ec2_instance_connect_endpoint.bastion.security_group_ids == toset(["sg-externaleice00000000"])
    error_message = "EICE endpoint should attach to the external eice SG"
  }

  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.source_security_group_id == "sg-externalbastion0000"
    error_message = "Cluster ingress rule should source from the external bastion SG"
  }
}

# ---------------------------------------------------------------------------
# Variable validation
# ---------------------------------------------------------------------------
#
# The two SG inputs (create flag + external ID) must be coordinated:
# exactly one path must be selected per SG.

run "validation_rejects_create_false_with_null_id" {
  command = plan

  variables {
    create_bastion_security_group = false
    bastion_security_group_id     = null
  }

  expect_failures = [var.bastion_security_group_id]
}

run "validation_rejects_create_true_with_external_id" {
  command = plan

  variables {
    create_bastion_security_group = true
    bastion_security_group_id     = "sg-shouldnotbeset000000"
  }

  expect_failures = [var.bastion_security_group_id]
}

# ---------------------------------------------------------------------------
# AMI lookup
# ---------------------------------------------------------------------------

run "ami_filter_default_is_al2023" {
  command = plan

  assert {
    condition     = length(var.ami_name_filter) == 1 && var.ami_name_filter[0] == "al2023-ami-2023.*-kernel-*-x86_64"
    error_message = "Default AMI filter should select the latest Amazon Linux 2023 x86_64 image"
  }

  assert {
    condition     = length(var.ami_owners) == 1 && var.ami_owners[0] == "amazon"
    error_message = "Default AMI owner should be 'amazon'"
  }
}

run "ami_filter_overridable" {
  command = plan

  variables {
    ami_name_filter = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
    ami_owners      = ["099720109477"]
  }

  # With overrides in place, data.aws_ami.bastion uses the caller's filters.
  # We can only verify the inputs flow through - the mock provider returns
  # a stub AMI regardless.
  assert {
    condition     = length(data.aws_ami.bastion.owners) == 1 && data.aws_ami.bastion.owners[0] == "099720109477"
    error_message = "AMI owner override should flow through to the data source"
  }
}

# ---------------------------------------------------------------------------
# Instance hardening
# ---------------------------------------------------------------------------

run "instance_requires_imdsv2" {
  command = plan

  assert {
    condition     = aws_instance.bastion.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required (http_tokens = 'required')"
  }

  assert {
    condition     = aws_instance.bastion.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit must be 1 to prevent metadata access via containers or proxies"
  }
}

run "instance_root_volume_encrypted" {
  command = plan

  assert {
    condition     = aws_instance.bastion.root_block_device[0].encrypted == true
    error_message = "Root block device must be encrypted"
  }
}

# ---------------------------------------------------------------------------
# user_data rendering
# ---------------------------------------------------------------------------
#
# The aws_instance.user_data attribute stores a hash, not plaintext. The
# module exposes the rendered script via the user_data_rendered output for
# test assertions.

run "user_data_substitutes_template_vars" {
  command = plan

  assert {
    condition     = strcontains(output.user_data_rendered, "aws eks update-kubeconfig --name 'test-cluster' --region 'us-east-2'")
    error_message = "user_data should substitute cluster_name and region into update-kubeconfig"
  }

  assert {
    condition     = strcontains(output.user_data_rendered, "git clone 'https://github.com/example/repo.git'")
    error_message = "user_data should include git clone line when repo_url is provided"
  }
}

run "user_data_skips_clone_when_repo_url_null" {
  command = plan

  variables {
    repo_url = null
  }

  assert {
    condition     = !strcontains(output.user_data_rendered, "git clone")
    error_message = "user_data should skip git clone when repo_url is null"
  }

  # update-kubeconfig should still run regardless of repo_url
  assert {
    condition     = strcontains(output.user_data_rendered, "aws eks update-kubeconfig")
    error_message = "user_data should still run update-kubeconfig when repo_url is null"
  }
}

# ---------------------------------------------------------------------------
# EKS access entry
# ---------------------------------------------------------------------------

run "eks_access_entry_created_for_bastion_role" {
  command = plan

  assert {
    condition     = aws_eks_access_entry.bastion.cluster_name == "test-cluster"
    error_message = "Access entry should target the configured cluster"
  }

  assert {
    condition     = aws_eks_access_entry.bastion.type == "STANDARD"
    error_message = "Access entry type should be STANDARD"
  }

  assert {
    condition     = aws_eks_access_policy_association.bastion.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "Access policy association should attach AmazonEKSClusterAdminPolicy"
  }

  assert {
    condition     = aws_eks_access_policy_association.bastion.access_scope[0].type == "cluster"
    error_message = "Access scope should be cluster-wide for an operator bastion"
  }
}

# ---------------------------------------------------------------------------
# Cluster SG ingress
# ---------------------------------------------------------------------------

run "cluster_sg_ingress_443_from_bastion" {
  command = plan

  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.type == "ingress"
    error_message = "Cluster SG rule should be ingress"
  }

  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.from_port == 443 && aws_security_group_rule.cluster_ingress_bastion.to_port == 443
    error_message = "Cluster SG rule should open TCP/443 for kubectl/helm"
  }

  assert {
    condition     = aws_security_group_rule.cluster_ingress_bastion.security_group_id == var.cluster_security_group_id
    error_message = "Cluster SG rule should attach to the caller-provided cluster SG"
  }
}