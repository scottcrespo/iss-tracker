locals {
  # Resolves SG IDs from whichever path the caller selected: the
  # module-managed SG when create_*_security_group is true, or the
  # externally-supplied <name>_security_group_id when it is false.
  # Downstream resources reference the local uniformly and do not need
  # to know which path produced the ID.
  bastion_sg_id = var.create_bastion_security_group ? one(aws_security_group.bastion[*].id) : var.bastion_security_group_id
  eice_sg_id    = var.create_eice_security_group ? one(aws_security_group.eice[*].id) : var.eice_security_group_id
}