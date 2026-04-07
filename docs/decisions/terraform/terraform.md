# Terraform — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Directory structure: environments/region segmentation
Terraform roots are organized by environment (`dev/`, `staging/`, `prod/`) and further segmented by scope (`global/`, `us-east-2/`). This means `terraform init/plan/apply` is always run from the specific directory being targeted, giving each resource group its own isolated state file. This is preferable to Terraform workspaces, which share backend config and make it easier to accidentally apply to the wrong environment.

## Bootstrap directory for admin-only resources
A dedicated `global/bootstrap/` directory isolates resources that must be created before any other Terraform can run (S3 state bucket, IAM roles). These are provisioned with admin credentials and are never touched by the `terraform-dev` role. Keeping them separate makes the privilege boundary explicit and prevents accidental destruction during normal infrastructure work.

## S3 remote state over local state
Terraform state is stored in S3 (`iss-tracker-tfstate-dev`) with server-side encryption (AES256) and versioning enabled. Versioning provides a recovery path if state is corrupted. A separate S3 bucket per environment (dev/staging/prod) ensures blast radius isolation — a misconfigured destroy in dev cannot affect prod state.

## Native S3 state locking (no DynamoDB)
As of Terraform 1.10, the S3 backend supports native state locking via S3 conditional writes (`use_lockfile = true`), eliminating the need for a DynamoDB lock table. Since the project is on Terraform 1.14.8 this is fully available. This simplifies the bootstrap — one less resource to provision and manage.

## Hardcoded bucket name in backend block
The S3 bucket name is a literal string in the backend block rather than a variable. This is a hard Terraform limitation — the backend block is evaluated before variables are loaded and does not support `var.*` interpolation. The bucket name is not a secret (S3 access is controlled entirely by IAM), so hardcoding it is acceptable. A comment in the resource explains this constraint.

## Bootstrap state migration pattern
The S3 state bucket is created with local state first, then `terraform init -migrate-state` is run after adding the backend block to move local state into S3. This is the standard approach to the bootstrap chicken-and-egg problem (you can't store state in a bucket that doesn't exist yet).

## S3 bucket security configuration
The state bucket is configured with:
- **Versioning** — recovery path for corrupted or accidentally deleted state
- **AES256 encryption** — state files contain resource metadata and should be encrypted at rest
- **Public access block** — all four public access settings disabled; state bucket should never be public
- **`prevent_destroy` lifecycle** — prevents accidental `terraform destroy` from deleting the state bucket

## .terraform.lock.hcl committed to repo
The provider lock file is committed to version control. It records the exact provider versions selected during `terraform init`, ensuring CI and all developers use identical provider binaries. It is distinct from state locking — it is not deleted when state migrates to S3.

## Planned decisions to document:
- Module structure and boundaries
- VPC design (public/private subnets, NAT gateway)
- EKS vs K3S on EC2 decision
- IRSA for pod-level AWS permissions
- Daily terraform destroy strategy for cost control
- DynamoDB table provisioning
- ECR repository setup
- terraform-dev IAM role scope and permissions