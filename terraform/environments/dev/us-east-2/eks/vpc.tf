module "vpc" {
  # v6.6.1
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=7a28ce8ec6a17a8ca52710e47763f3a52c155110"
  name   = local.cluster_name
  cidr   = local.vpc_cidr

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
    # UDP ephemeral return traffic — CoreDNS responses arrive with dest port in
    # the ephemeral range (source port 53 on CoreDNS, dest port = pod's query
    # port). NACLs are stateless so this must be explicit; the TCP rule above
    # does not cover UDP.
    {
      rule_number = 105
      rule_action = "allow"
      protocol    = "udp"
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
    # Scoped to private_subnets_aggregate (10.0.0.0/22) rather than vpc_cidr —
    # only the private tier legitimately communicates with intra tier resources
    # (CoreDNS, VPC endpoints). Public subnets must not have a NACL-permitted
    # path into the intra tier.
    {
      rule_number = "100"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "443"
      to_port     = "443"
      cidr_block  = local.private_subnets_aggregate
    },
    # Intra-to-intra HTTPS — pods reaching the API server control plane ENI or
    # VPC endpoints in other intra subnets (LB controller, leader election, webhooks).
    # Uses intra_subnets_aggregate (10.0.48.0/21) — see main.tf locals for rationale.
    {
      rule_number = "101"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "443"
      to_port     = "443"
      cidr_block  = local.intra_subnets_aggregate
    },
    # DNS TCP — from private subnet pods
    {
      rule_number = "110"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.private_subnets_aggregate
    },
    # DNS TCP — intra-to-intra (kube-system pods querying CoreDNS in other intra subnets)
    {
      rule_number = "111"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.intra_subnets_aggregate
    },
    # DNS UDP — from private subnet pods
    {
      rule_number = "120"
      rule_action = "allow"
      protocol    = "udp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.private_subnets_aggregate
    },
    # DNS UDP — intra-to-intra (kube-system pods querying CoreDNS in other intra subnets)
    {
      rule_number = "121"
      rule_action = "allow"
      protocol    = "udp"
      from_port   = "53"
      to_port     = "53"
      cidr_block  = local.intra_subnets_aggregate
    },
    # UDP ephemeral return traffic — VPC DNS resolver (10.0.0.2) responds to
    # CoreDNS forwarded queries with UDP from port 53 to CoreDNS's ephemeral
    # port. NACLs are stateless so this must be explicit; the TCP rule below
    # does not cover UDP.
    {
      rule_number = "125"
      rule_action = "allow"
      protocol    = "udp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = local.private_subnets_aggregate
    },
    # UDP ephemeral return traffic — intra-to-intra (CoreDNS responses to kube-system
    # pods in other intra subnets, and other intra-to-intra UDP return traffic)
    {
      rule_number = "126"
      rule_action = "allow"
      protocol    = "udp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = local.intra_subnets_aggregate
    },
    # Ephemeral ports — return traffic from VPC endpoints to private subnet pods
    {
      rule_number = "130"
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = "1024"
      to_port     = "65535"
      cidr_block  = local.private_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
    },
    # API traffic — scoped to private subnets (API pods run in private tier)
    {
      rule_number = 180
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.private_subnets_aggregate
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
    # DNS TCP — to private subnet pods
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.private_subnets_aggregate
    },
    # DNS TCP — intra-to-intra (kube-system pods querying CoreDNS in other intra subnets)
    {
      rule_number = 111
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.intra_subnets_aggregate
    },
    # DNS UDP — to private subnet pods
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.private_subnets_aggregate
    },
    # DNS UDP — intra-to-intra (kube-system pods querying CoreDNS in other intra subnets)
    {
      rule_number = 121
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = local.intra_subnets_aggregate
    },
    # Ephemeral return traffic (TCP) — to private subnet pods only
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.private_subnets_aggregate
    },
    # Ephemeral return traffic (UDP) — CoreDNS UDP responses back to private
    # subnet pods. DNS queries arrive on UDP 53; responses leave from port 53
    # to the client's ephemeral port. NACLs are stateless so this outbound
    # rule is required even though the inbound query was permitted.
    {
      rule_number = 135
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.private_subnets_aggregate
    },
    # Ephemeral return traffic (TCP) — intra-to-intra (API server ENI → webhook pods,
    # LB controller → API server, etc.)
    {
      rule_number = 136
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.intra_subnets_aggregate
    },
    # Ephemeral return traffic (UDP) — intra-to-intra (CoreDNS responses to kube-system
    # pods in other intra subnets). NACLs are stateless; rule 135 only covers private subnets.
    {
      rule_number = 141
      rule_action = "allow"
      protocol    = "udp"
      from_port   = 1024
      to_port     = 65535
      cidr_block  = local.intra_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
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
      cidr_block  = local.private_subnets_aggregate
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
    # Response traffic from internet to NAT gateway (bastion/pod egress via NAT)
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
    # LB forwarding to API pods in private subnets
    {
      rule_number = 110
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 8000
      to_port     = 8000
      cidr_block  = local.vpc_cidr
    },
    # NAT gateway forwarding HTTPS to internet (bastion and pod egress)
    {
      rule_number = 120
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = "0.0.0.0/0"
    },
    # NAT gateway forwarding HTTP to internet
    {
      rule_number = 130
      rule_action = "allow"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_block  = "0.0.0.0/0"
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