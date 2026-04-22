# AWS Context — ISS Tracker

Patterns, anti-patterns, and known gotchas for AWS usage in this project.

**Update this document when:**
- A new VPC endpoint is added — update the gotchas and reference the lessons-learned entry
- A new IAM governance rule is established — add to the IAM Governance section
- A new IAM permission gap is discovered and fixed — add to the LB controller drift gotcha or create a new entry
- AWS service behavior changes or a new AWS-specific constraint is discovered

---

## IAM Governance

Rules that apply to all IAM resources provisioned by this project:

1. **Permission boundaries on created roles.** Any role with IAM write permissions
   must attach a permission boundary to every role it creates. The boundary must
   include resource scoping constraints to prevent privilege escalation.
2. **OIDC trust policies use `StringEquals`.** Conditions on OIDC-federated trust
   policies must use `StringEquals` on the exact namespace and service account name.
   `StringLike` and wildcard subjects are not permitted.
3. **One role per workload.** No IAM role is shared across services or workloads.
   A compromised pod must not be able to perform another workload's actions.
4. **CI/CD plan and apply roles are strictly separated.** The apply role is never
   used for read-only operations; the plan role never has write permissions.
5. **Policy content is always caller-defined.** Terraform modules may provision
   IAM role structure but never define policy documents. All policy content is
   supplied by the calling root module.

---

## Patterns

**Identity and access**
- All workload identity uses IRSA — pods never rely on the node IAM role for
  application permissions
- One IAM role per workload, scoped to its minimum required actions and resources
- OIDC trust policies use `StringEquals` conditions on exact namespace and
  service account name — never `StringLike` or wildcard subject
- CI/CD uses separate plan and apply IAM roles with permission boundaries;
  apply role is never used for read-only operations

**Networking**
- All AWS service communication routes through VPC endpoints — no internet path
  for AWS APIs on private or intra subnets
- Gateway endpoints (S3, DynamoDB) are free and have no SG; added to both intra
  and private route tables
- Interface endpoint ENIs are placed in intra subnets; private subnet pods reach
  them via VPC-local routing
- Two endpoint SGs scope ingress by subnet tier (`vpc_endpoints_intra`,
  `vpc_endpoints_private`) — both attached to every interface endpoint
- S3 egress in security groups uses the AWS-managed prefix list
  (`com.amazonaws.us-east-2.s3`) not CIDR blocks

**Descriptions and tags**
- All `description` fields use plain hyphens — em dashes (`—`) are rejected by
  the AWS API
- Subnets used for internet-facing ALBs are tagged `kubernetes.io/role/elb: 1`;
  internal subnets tagged `kubernetes.io/role/internal-elb: 1` — required for
  ALB controller auto-discovery

---

## Anti-patterns

- **No long-lived credentials.** No AWS access keys stored anywhere — not in
  `.env` files, GitHub secrets, or EC2 instance metadata beyond IRSA tokens
- **No secrets in Git.** Account IDs, ARNs, and ECR URLs are not committed;
  they are injected at deploy time or stored in AWS Secrets Manager
- **No shared IAM roles across workloads.** A compromised poller pod should not
  be able to perform API pod actions
- **No public ECR or public EKS endpoint.** ECR is private; EKS API server is
  private-endpoint-only
- **No `aws configure` in scripts.** `aws configure get region` exits code 1
  when region is set via environment variable, silently killing scripts that use
  `set -e`. Hardcode `us-east-2` instead

---

## Known Gotchas

**VPC endpoint discovery is incremental.** Private clusters surface missing
endpoints as connection timeouts — one at a time, as each component first tries
to reach its service. Expect to add endpoints reactively. Current required set
is documented in `docs/lessons-learned/private-eks-fargate-debugging.md`.

**LB controller IAM policy drifts from the AWS reference.** The official policy
lags behind newer controller versions. Known gaps already fixed in this project:
- `elasticloadbalancing:AddTags` requires a second statement scoped to
  `CreateAction` for newly-created resources (the reference policy only covers
  existing resources)
- `elasticloadbalancing:DescribeListenerAttributes` is missing from the reference
  policy entirely

**AWS Shield timeout is non-blocking.** The LB controller logs a warning about
being unable to reach the Shield API — this is safe to ignore. Shield Advanced
is not enabled and the controller skips reconciliation for it.

**ECR image layers route through S3 with public IPs.** Even on a private cluster,
ECR layer pulls resolve to public S3 IP addresses. NACLs must permit these IPs
even though the traffic stays within AWS via the S3 gateway endpoint. See the
`0.0.0.0/0` rationale in `docs/decisions/terraform/eks.md`.

**Terraform state drift on security group rules.** SG rules added in terraform
config are not always reflected in AWS state after a plan/apply cycle — likely
due to interrupted prior applies. When traffic is still rejected despite a rule
existing in config, verify with `aws ec2 describe-security-group-rules` before
adding manual workarounds.