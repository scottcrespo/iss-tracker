module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"
  name    = local.cluster_name
  cidr    = local.vpc_cidr

  azs = ["us-east-2a", "us-east-2b", "us-east-2c"]

  # ---------------------------------------------------------------------------
  # Private subnets — Fargate pods that need internet egress (iss-tracker)
  # ---------------------------------------------------------------------------
  # NAT gateway provides outbound internet so the poller can reach the public
  # ISS position API. A single NAT gateway is sufficient for dev — one per AZ
  # would be required for production HA.
  private_subnets               = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_dedicated_network_acl = true
  private_inbound_acl_rules = [
    # Return traffic from internet via NAT gateway (ISS API responses) and
    # from VPC endpoints in intra subnets. A single 0.0.0.0/0 rule covers
    # both: NAT returns arrive with public source IPs; VPC endpoint returns
    # arrive with intra subnet IPs (within 0.0.0.0/0).
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = "0.0.0.0/0"
    },
    # ALB forwarding to API pods
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
    # DNS responses from CoreDNS (UDP)
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # DNS responses from CoreDNS (TCP fallback)
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 3 - Destination Unreachable (Path MTU Discovery)
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
  ]
  private_outbound_acl_rules = [
    # HTTPS to 0.0.0.0/0 covers two distinct paths:
    #   1. VPC endpoint ENIs in intra subnets (10.0.51.x) — traffic stays
    #      within the VPC via local routing
    #   2. Internet via NAT gateway (ISS position API)
    # See intra outbound rule 100 comment for the correct long-term NACL
    # approach; the same S3 prefix list reasoning applies here.
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = "0.0.0.0/0"
    },
    # HTTP to internet via NAT (ISS API may redirect HTTP -> HTTPS)
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_block  = "0.0.0.0/0"
    },
    # DNS to CoreDNS pods in intra subnets (UDP)
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # DNS to CoreDNS pods in intra subnets (TCP fallback)
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.vpc_cidr
    },
    # Ephemeral return traffic to ALB in public subnets and other VPC callers
    {
      rule_number = 140
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.vpc_cidr
    },
    # ICMP type 3 - Destination Unreachable (Path MTU Discovery)
    {
      rule_number = 150
      rule_action = "allow"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      icmp_type   = 3
      icmp_code   = -1
      cidr_block  = local.vpc_cidr
    },
  ]

  # ---------------------------------------------------------------------------
  # Intra subnets — Fargate pods with no internet egress (kube-system)
  # ---------------------------------------------------------------------------
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
    # Ephemeral ports from VPC (return traffic from VPC endpoints)
    {
      rule_number = "130"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = local.vpc_cidr
    },
    # 0.0.0.0/0 is intentional. Return traffic from S3 layer downloads arrives
    # from public S3 IPs via the S3 gateway endpoint. Same reasoning as the
    # outbound rule above — traffic stays within AWS, no internet route exists.
    # See outbound rule 100 comment for the correct long-term approach.
    {
      rule_number = "140"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = "0.0.0.0/0"
    },
    # ICMP type 3 — Destination Unreachable (includes Path MTU Discovery)
    {
      rule_number = 150
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
      rule_number = 160
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
      rule_number = 170
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
      rule_number = 180
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
  ]
  intra_outbound_acl_rules = [
    # 0.0.0.0/0 is intentional. ECR layer downloads resolve to public S3 IPs
    # (prod-us-east-2-starport-layer-bucket) which are routed through the S3
    # gateway endpoint. Traffic never reaches the internet — intra subnets have
    # no IGW or NAT. NACLs evaluate the raw destination IP before routing, so
    # public S3 IPs must be permitted here even though traffic stays in AWS.
    #
    # The correct approach would be to enumerate the S3 managed prefix list
    # entries (aws_ec2_managed_prefix_list_entries data source) and create one
    # aws_network_acl_rule per CIDR using for_each — NACLs cannot reference
    # prefix lists directly. Not implemented here: the complexity of moving
    # away from the vpc module's NACL inputs isn't justified for this project.
    {
      rule_number = 100
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = "0.0.0.0/0"
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
    # Return traffic from API pods in private subnets
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.vpc_cidr
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
    # LB forwarding to API pods in private subnets
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
  ]

  # Single NAT gateway for dev cost control. One per AZ would be required
  # for production HA — a single NAT GW is a single point of failure.
  enable_nat_gateway = true
  single_nat_gateway = true
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

  # Private subnets host iss-tracker Fargate pods. The cluster tag lets the
  # VPC CNI discover these subnets for branch ENI placement.
  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}