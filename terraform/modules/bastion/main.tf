# ---------------------------------------------------------------------------
# Bastion EC2 instance
# ---------------------------------------------------------------------------
#
# Default AMI lookup is the latest Amazon Linux 2023 x86_64 image, which
# has ec2-instance-connect pre-installed and matches the dnf/ec2-user
# assumptions in user_data.sh.tpl. Callers can override the name filter
# and owners to use Ubuntu, Bottlerocket, or a custom AMI - see the
# corresponding note on var.ami_name_filter.
#
# The rendered user_data is exposed as a module output so tests and
# operators can inspect the script without decoding instance state.

data "aws_ami" "bastion" {
  most_recent = true
  owners      = var.ami_owners

  filter {
    name   = "name"
    values = var.ami_name_filter
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  user_data_rendered = templatefile("${path.module}/user_data.sh.tpl", {
    cluster_name = var.cluster_name
    region       = var.region
    repo_url     = var.repo_url
  })
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.bastion.id
  instance_type          = var.instance_type
  subnet_id              = var.bastion_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [local.bastion_sg_id]

  # IMDSv2 required - token-based metadata requests only. IMDSv1 allows
  # unauthenticated HTTP requests to the metadata endpoint, which is
  # exploitable via SSRF. hop_limit = 1 prevents forwarded requests from
  # reaching the metadata service via containers or proxies.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted = true
  }

  user_data = local.user_data_rendered

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion" })
}