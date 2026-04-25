# ---------------------------------------------------------------------------
# EC2 Instance Connect Endpoint (EICE)
# ---------------------------------------------------------------------------
#
# Proxies SSH connections to the bastion over the instance's private IP.
# No public IP is required on the bastion host.
# No public IP, no inbound internet port, no pre-registered SSH keys.
#
# The EICE SG and its egress rule are gated by var.create_eice_security_group.
# The EICE endpoint itself is always created - it consumes local.eice_sg_id,
# which resolves to either the module-managed SG or the externally-supplied
# eice_security_group_id. Cross-reference to the bastion SG flows through
# local.bastion_sg_id, which resolves under any combination of toggles.

resource "aws_security_group" "eice" {
  #checkov:skip=CKV2_AWS_5: SG is attached to the EC2 Instance Connect Endpoint in eice.tf - Checkov cannot trace the attachment through the module
  count = var.create_eice_security_group ? 1 : 0

  name        = "${var.name_prefix}-eice"
  description = "EICE - SSH outbound to bastion"
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_security_group_rule" "eice_egress_ssh_to_bastion" {
  count = var.create_eice_security_group ? 1 : 0

  description              = "SSH to bastion"
  type                     = "egress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = local.eice_sg_id
  source_security_group_id = local.bastion_sg_id
}

resource "aws_ec2_instance_connect_endpoint" "bastion" {
  subnet_id          = var.eice_subnet_id
  security_group_ids = [local.eice_sg_id]
  preserve_client_ip = false

  tags = var.tags
}