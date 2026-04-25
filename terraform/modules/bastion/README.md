# Bastion module

Provisions a private bastion host for operator access to a private EKS cluster.
Bundles the EC2 instance, IAM role and instance profile, EC2 Instance Connect
Endpoint (EICE), security groups, and the EKS access entry that grants the
bastion's IAM role cluster-admin on the target cluster.

Access flow: operator runs `aws ec2-instance-connect ssh --instance-id ...`
from their workstation. AWS tunnels the SSH session through the EICE to the
bastion. The bastion has `kubectl` and `helm` installed by user_data and the
IAM role has cluster-admin via an EKS access entry, so `kubectl` works
immediately on login.

See `vars.tf` and `outputs.tf` for the full input and output reference.
Variable descriptions are the source of truth; this README covers intent and
the non-obvious patterns.

## Usage

```hcl
module "bastion" {
  source = "git::https://github.com/scottcrespo/iss-tracker.git//terraform/modules/bastion?ref=<commit-sha>"

  name_prefix               = "iss-tracker-eks-dev"
  vpc_id                    = module.vpc.vpc_id
  bastion_subnet_id         = module.vpc.private_subnets[0]
  eice_subnet_id            = module.vpc.private_subnets[0]
  cluster_name              = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  region                    = "us-east-2"
  repo_url                  = "https://github.com/scottcrespo/iss-tracker.git"

  iam_policies = {
    eks_describe = data.aws_iam_policy_document.bastion_eks_describe.json
  }

  tags = local.tags
}
```

At minimum, callers should supply an `iam_policies` entry granting
`eks:DescribeCluster` on the target cluster so `aws eks update-kubeconfig`
(run during user_data) can fetch cluster details.

## Patterns

### IAM policy content is caller-defined

The module provisions the role, instance profile, and trust relationship but
contributes no policy content of its own. All inline policies are passed in
via `var.iam_policies` as a map of policy name to JSON document string. This
enforces the project's IAM Governance rule that module authors never decide
what an identity is allowed to do.

The `tests/` directory includes terraform native test cases asserting that
injected policy documents are attached byte-for-byte (content equality via
`jsondecode`) and that the module attaches no policies the caller did not
supply (count equality).

### Security groups are caller-toggleable

The module creates two security groups by default:

- **Bastion SG** — SSH ingress from the EICE SG, HTTPS egress to anywhere
- **EICE SG** — SSH egress to the bastion SG

Each SG has two coordinated inputs: `create_<name>_security_group` (bool,
default `true`) and `<name>_security_group_id` (string, default `null`).

- **Create path** (default): `create_*_security_group = true`,
  `*_security_group_id = null`. The module creates the SG and its
  pre-baked rules as a bundle.
- **External path**: `create_*_security_group = false`,
  `*_security_group_id = "sg-..."`. The module skips the SG and its
  bundled rules; downstream resources (bastion instance, EICE endpoint,
  cluster ingress rule, cross-reference rules) consume the external ID
  via an internal local.

Exactly one path must be used per SG, enforced by variable validation.

The two SGs are fully independent - any combination of paths is supported.
The cross-reference rules (bastion ingress from EICE, EICE egress to
bastion) and the cluster ingress rule all resolve their SG IDs through
locals, so they function correctly whether each SG is module-managed or
externally supplied.

### AMI lookup is overridable

Defaults to the latest Amazon Linux 2023 x86_64 image (`var.ami_name_filter`
and `var.ami_owners`). The user_data template assumes `dnf`, `/home/ec2-user`,
and pre-installed `ec2-instance-connect` — non-AL2023 AMIs will require
corresponding user_data changes.

### user_data is template-only

The bundled `user_data.sh.tpl` installs `git`, `kubectl`, and `helm`, then
runs `aws eks update-kubeconfig` and optionally `git clone` the caller's
repo. It includes a first-boot network readiness probe to handle the NAT
route / DNS / SG convergence race.

For anything beyond this baseline (additional tooling, configuration
management, idempotent re-runs), the right approach is either a full
user_data override via module fork or an external configuration tool
(Ansible, SSM State Manager). Both are outside this module's scope.

The rendered user_data is exposed as the `user_data_rendered` output — the
`aws_instance.user_data` attribute stores a hash, not the plaintext, so this
output is the only way tests and operators can inspect the actual script
content.

## EKS access entry

The module creates an `aws_eks_access_entry` for the bastion's IAM role and
associates the AWS-managed `AmazonEKSClusterAdminPolicy` at cluster scope.
This is the modern EKS access API that supersedes the legacy `aws-auth`
ConfigMap pattern: the role is registered on the cluster and mapped to
Kubernetes RBAC via an AWS-managed policy, no in-cluster config required.

Cluster-admin is appropriate for an operator bastion. For multi-user or
production shared bastions, the access policy association should be scoped
down — e.g., `AmazonEKSViewPolicy` for read-only operators, namespace-scoped
associations for team-specific bastions.

## Tests

Run from the module directory:

```bash
cd terraform/modules/bastion
terraform init
terraform test
```

Tests use `mock_provider "aws" {}` — no AWS credentials or live resources
required. See `tests/bastion.tftest.hcl` for the full test suite.