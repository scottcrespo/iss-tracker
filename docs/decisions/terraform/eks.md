# EKS Cluster — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Fargate workers

Fargate is used instead of managed node groups. Workers run on AWS-managed infrastructure — there are no EC2 nodes to patch, scale, or manage.

### Tradeoffs accepted
- No DaemonSets. Node-level agents (node-exporter, Fluentd as a DaemonSet) cannot run on Fargate. Observability tooling must be adapted — see the observability decisions in `docs/decisions/k8s/k8s.md`.
- CoreDNS must be patched to run on Fargate. The EKS Terraform module handles this but it is a required configuration step.
- Slightly higher per-vCPU/memory cost than EC2 for sustained workloads. Acceptable for a demonstration project where operational simplicity and cost predictability matter more than raw cost efficiency.

### Why this is the right call for this project
The project exists to demonstrate platform engineering skills, not to operate production infrastructure at scale. Fargate eliminates node group sizing, AMI management, and cluster autoscaler configuration — all of which would add complexity without adding learning value relative to the project's goals. The tradeoffs are documented and defensible.

## VPC design

A dedicated VPC is provisioned using `terraform-aws-modules/vpc`. No default VPC resources are used.

### Subnet layout

| Subnet type | Used for | Internet egress |
|-------------|----------|----------------|
| Public | Load balancers only | Yes (IGW) |
| Intra | Fargate pods, EKS nodes | None |

Fargate pods run in intra subnets — no NAT gateway, no internet route. This is intentional: workloads should not have direct internet egress. All outbound AWS service access is handled through VPC endpoints.

### VPC endpoints

Because intra subnets have no internet route, all AWS service communication requires VPC endpoints. The following endpoints are required for Fargate pods to function:

| Service | Endpoint type | Purpose |
|---------|--------------|---------|
| `ecr.api` | Interface | ECR image metadata |
| `ecr.dkr` | Interface | ECR image layer pulls |
| `s3` | Gateway | ECR stores image layers in S3 |
| `logs` | Interface | CloudWatch log delivery |
| `sts` | Interface | IRSA token exchange |
| `eks` | Interface | Cluster API communication |

A missing endpoint produces cryptic failures — pods stuck in `Pending` or containers failing with connection refused at startup. The endpoint list above is the minimum required set. The S3 gateway endpoint is free; interface endpoints have an hourly cost per AZ.

### NACLs
NACLs are defined explicitly rather than relying on default rules. This provides a network-layer defense-in-depth control and demonstrates understanding of the distinction between NACLs (stateless, subnet-level) and security groups (stateful, resource-level).

#### S3 gateway endpoint — NACL and security group behavior

ECR stores image layers in S3. When Fargate pulls an image, the ECR DKR endpoint handles the manifest lookup, but the actual layer data is fetched via presigned S3 URLs that resolve to **public S3 IP addresses** (e.g., `prod-us-east-2-starport-layer-bucket.s3.us-east-2.amazonaws.com`). This traffic is routed through the S3 gateway endpoint and never reaches the internet — intra subnets have no IGW or NAT route. However, both NACLs and security groups evaluate the raw destination IP before routing takes effect, so the public S3 IP range must be explicitly permitted at both layers even though the traffic stays within AWS.

**Security group:** The node security group egress rule uses the AWS-managed S3 prefix list (`com.amazonaws.us-east-2.s3`) via `prefix_list_ids`. This is precise and automatically stays current as AWS updates their IP ranges.

**NACLs:** NACLs cannot reference prefix lists — only CIDR blocks. The theoretically correct approach is to enumerate the S3 prefix list entries using the `aws_ec2_managed_prefix_list_entries` data source and create one `aws_network_acl_rule` per CIDR using `for_each`. This project uses `0.0.0.0/0` in the intra subnet NACL rules instead.

This is not simply a "good enough for a portfolio project" shortcut — `0.0.0.0/0` is actually the more operationally sound choice. AWS periodically updates the S3 prefix list as IP ranges change. During a `terraform apply` that reflects those changes, Terraform deletes old NACL rules and creates new ones, opening a window of partial S3 coverage. Any image pull during that window fails, and if the apply involves EKS resources, broken image pulls can cascade into failed deployments. The `0.0.0.0/0` rule never changes and carries none of that risk. The routing layer (no IGW, no NAT in intra subnets) is the durable compensating control — only gateway endpoint destinations are actually reachable regardless of what the NACL permits.

This outcome also validates the original decision to place EKS nodes and Fargate pods in intra subnets. At the time, the motivation was to eliminate internet egress from workloads as a security posture. In practice, it turned out that the S3 gateway endpoint behavior forces NACL rules that appear permissive on paper. The intra subnet design is what makes those rules safe — without an IGW or NAT route, `0.0.0.0/0` in a NACL is not a meaningful exposure. A cluster placed in private subnets with a NAT gateway would face the same NACL constraint but with actual internet routing present, making the permissive rules a genuine risk rather than a theoretical one.

### VPC flow logs
Flow logs are enabled and delivered to CloudWatch. This is a standard security and observability control — required in any real production environment for incident investigation and compliance.

## IAM ownership boundary

Pre-built modules (`terraform-aws-modules/eks`, `terraform-aws-modules/vpc`) are used for infrastructure provisioning. All IAM policy content remains caller-defined — modules may provision IAM resources but do not define policy documents.

Specifically:
- The EKS module is permitted to create the cluster OIDC provider
- All IRSA role trust policies and permission policies are defined in this codebase, consuming the OIDC provider ARN output from the EKS module
- Node group and cluster IAM roles follow the same pattern: role structure via module, policy content via caller-supplied documents

This maintains the security ownership principle established in the IAM module design: the operator controls what entities can do, not just that they exist.

## Pre-built vs DIY module split

| Component | Approach | Rationale |
|-----------|----------|-----------|
| VPC | `terraform-aws-modules/vpc` | Well-understood, implemented many times previously — not differentiating |
| EKS cluster + Fargate profiles | `terraform-aws-modules/eks` | Complex compute/networking configuration, not the learning focus |
| Cluster IAM role | DIY | Security surface — trust policy and permissions matter |
| Node IAM role | DIY | Defines what nodes can access — security-adjacent |
| OIDC provider | EKS module output consumed | Avoids duplicate resource; module exposes ARN for IRSA use |
| IRSA roles | DIY | Core learning objective; same pattern as existing OIDC role modules |