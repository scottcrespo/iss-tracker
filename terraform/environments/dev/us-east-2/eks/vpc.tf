module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"
  name    = local.cluster_name
  cidr    = local.vpc_cidr

  azs                         = ["us-east-2a", "us-east-2b", "us-east-2c"]
  intra_subnets               = ["10.0.51.0/24", "10.0.52.0/24", "10.0.53.0/24"]
  intra_dedicated_network_acl = true
  intra_inbound_acl_rules = [
    {
      rule_number = "100"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "443"
      to_port     = "443"
      cidr_block  = local.vpc_cidr
    },
    # DNS TCP
    {
      rule_number = "110"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.vpc_cidr
    },
    # DNS UDP
    {
      rule_number = "120"
      rule_action = "allow"
      protocol    = "udp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.vpc_cidr
    },
    # Ephemeral Ports
    {
      rule_number = "130"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 3 — Destination Unreachable (includes Path MTU Discovery)
    {
      rule_number = 140
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1 # not used for icmp, but required by the module
      to_port     = -1
      icmp_type   = 3
      icmp_code   = -1 # -1 = all codes under type 3
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 8 — Echo Request (ping inbound)
    {
      rule_number = 150
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 8
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 0 — Echo Reply (ping outbound)
    {
      rule_number = 160
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 0
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
    # API traffic from load balancer in public subnets
    {
      rule_number = 170
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
  ]
  intra_outbound_acl_rules = [
    # HTTPS — pods to VPC endpoints, pods to control plane ENIs
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = local.vpc_cidr
    },
    # DNS TCP
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # DNS UDP
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # Ephemeral return traffic
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 3 — Destination Unreachable (Path MTU Discovery)
    {
      rule_number = 140
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 3
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 0 — Echo Reply (ping outbound)
    {
      rule_number = 150
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 0
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 8 — Echo Request (ping outbound)
    {
      rule_number = 160
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 8
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
  ]
  public_subnets               = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  public_dedicated_network_acl = true
  public_inbound_acl_rules = [
    # Internet HTTP
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_block  = "0.0.0.0/0"
    },
    # Internet HTTPS
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = "0.0.0.0/0"
    },
    # Return traffic from API pods in intra subnets
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.vpc_cidr
    },
    # Return traffic from internet (bastion outbound connections - SSM, helm, kubectl)
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = "0.0.0.0/0"
    },
  ]
  public_outbound_acl_rules = [
    # Return traffic to internet clients
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = "0.0.0.0/0"
    },
    # LB forwarding to API pods in intra subnets
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
    # Bastion HTTPS to internet (helm repos, kubectl downloads)
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = "0.0.0.0/0"
    },
  ]

  # Because we're using fargate, internet egress is not necessary
  enable_nat_gateway = false
  enable_vpn_gateway = false

  # Subnet tags required for EKS and the AWS Load Balancer Controller to
  # discover subnets automatically.
  #
  # kubernetes.io/role/elb=1          — ALB controller places public-facing
  #                                     load balancers in these subnets
  # kubernetes.io/role/internal-elb=1 — ALB controller places internal
  #                                     load balancers in these subnets
  # kubernetes.io/cluster/<name>=shared — marks subnets as available to the
  #                                       cluster for ENI placement
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  intra_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}