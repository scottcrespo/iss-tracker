# ---------------------------------------------------------------------------
# Bastion security group
# ---------------------------------------------------------------------------
#
# The SG and its pre-baked rules (SSH ingress from EICE, HTTPS egress) are
# gated by var.create_bastion_security_group. Cross-references to the EICE
# SG flow through local.eice_sg_id, which resolves whether the EICE SG is
# module-managed or externally supplied, so the ingress rule works under
# any combination of toggles.

resource "aws_security_group" "bastion" {
  count = var.create_bastion_security_group ? 1 : 0

  name        = "${var.name_prefix}-bastion"
  description = "Bastion - EICE inbound SSH, HTTPS outbound"
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_security_group_rule" "bastion_ingress_ssh_from_eice" {
  count = var.create_bastion_security_group ? 1 : 0

  description              = "SSH from EICE"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = local.bastion_sg_id
  source_security_group_id = local.eice_sg_id
}

resource "aws_security_group_rule" "bastion_egress_https" {
  count = var.create_bastion_security_group ? 1 : 0

  description       = "HTTPS to internet and VPC endpoints"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = local.bastion_sg_id
  cidr_blocks       = ["0.0.0.0/0"]
}