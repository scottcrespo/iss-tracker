# Security Context — ISS Tracker

Security principles, controls by layer, and iteration sequence for this project.

**Update this document when:**
- Container security hardening is complete — move the secure baseline planned items to current baseline
- ESO is in place — add secrets management pattern to the identity and access controls section
- A new security principle or anti-pattern is established
- The security iteration sequence changes

---

## Core Principles

**Least privilege.** Every identity — IAM role, Kubernetes service account, CI/CD
role — is scoped to the minimum permissions required for its specific function.
When in doubt, start with less and add as needed. Never grant access speculatively.

**Defense in depth.** No single control is relied upon exclusively. Multiple
independent layers protect the same asset so that a misconfiguration or failure
in one layer does not result in a full exposure. Example: intra subnet pods are
constrained by routing (no IGW/NAT), security group rules, and NACLs — three
independent controls. The routing layer makes permissive-looking NACL rules safe
in practice.

**Private by default.** Resources are private unless there is a specific,
justified requirement for public access. The only intentionally public resource
in this project is the ALB. ECR, EKS API, DynamoDB, and all inter-service
communication are private.

**No secrets in source control.** Credentials, account IDs, ARNs, and ECR URLs
are never committed. Sensitive values are injected at deploy time or stored in
AWS Secrets Manager. The repository is safe to be public.

**Separation of duties.** Each workload has its own IAM role. No identity
accumulates permissions beyond its function.

---

## Security Controls by Layer

**Network**
- Three subnet tiers enforce routing constraints: intra (no internet), private
  (NAT egress only), public (ALB only)
- Explicit NACLs on all subnet tiers — stateless, subnet-level control
- Per-namespace security groups via `SecurityGroupPolicy` — pod-level control
- All AWS service communication via VPC endpoints — no internet path for AWS APIs
- No inbound internet access to any compute resource (bastion uses EC2 Instance
  Connect Endpoint; no public IPs assigned)

**Identity and access**
- IRSA binds Kubernetes service accounts to IAM roles via OIDC federation
- Trust policies use `StringEquals` on exact namespace and service account name
- Permission boundaries on all roles with IAM write permissions
- No long-lived AWS credentials anywhere in the system

**CI/CD**
- GitHub Actions does not have AWS credentials or cluster access. This project
  runs on a public repository — GitHub Actions workflow logs are publicly visible.
  AWS and Terraform tooling can emit account IDs, ARNs, and other sensitive values
  in log output regardless of stdout suppression attempts. Granting CI/CD any AWS
  or cluster access would risk credential and account data exposure via public logs.
- Image builds and ECR pushes are performed manually
- See `docs/context/cicd.md` and `docs/decisions/cicd/cicd.md`

**Container runtime (current baseline)**
- IRSA projected tokens for AWS API access — no static credentials in containers
- Image references use SHA256 digest — immutable, not tag-based

**Container runtime (secure baseline — planned)**
- `runAsNonRoot: true`, explicit `runAsUser` and `runAsGroup`
- `readOnlyRootFilesystem: true`
- Drop all Linux capabilities; add back only what is explicitly required
- `seccompProfile: RuntimeDefault`
- Kubernetes RBAC scoped to minimum required verbs and resources
- `automountServiceAccountToken: false` where IRSA projected token is used instead
- NetworkPolicy restricting pod egress to required endpoints only

---

## Security Iteration Sequence

New capabilities follow a two-phase security delivery model:

**Phase 1 — Functional baseline**
Infrastructure-level controls in place before the feature is considered
functional: least-privilege IAM, network segmentation, VPC endpoint access only
where applicable, no secrets in Git.

**Phase 2 — Secure baseline**
Runtime-level controls layered on top: source and container image scanning,
`SecurityContext`, `seccompProfile`, RBAC, `ServiceAccount` policies,
`NetworkPolicy`. Phase 2 is a required iteration, not optional cleanup.

---

## Anti-patterns

- **Never grant `*` actions or `*` resources in IAM** without a documented,
  time-bounded justification and compensating controls
- **Never use `privileged: true`** in a container security context
- **Never disable seccomp** (`seccompProfile: Unconfined`) without explicit
  justification
- **Never store secrets as plaintext environment variables** in pod specs or
  Helm values — use projected IRSA tokens or External Secrets Operator
- **Never expose the Kubernetes API server publicly** — EKS endpoint is
  private-only; all kubectl access is via bastion
- **Never use `vpc_cidr` in intra-tier NACL rules** — the VPC CIDR includes
  public subnets, which must not have a NACL-permitted path into the intra tier.
  Scope NACL rules to the specific subnet-tier CIDRs that legitimately originate
  the traffic (e.g., private subnet CIDRs for private → intra DNS). Using the
  full VPC CIDR defeats the defense-in-depth model where each subnet tier has
  distinct trust boundaries.