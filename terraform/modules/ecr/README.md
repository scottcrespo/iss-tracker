# Module: ecr

Provisions an Amazon ECR repository with image scanning, configurable encryption, and lifecycle policies to control storage costs.

## Features

- Image scanning on push (reports CVEs without blocking pushes)
- Configurable encryption: AES256 (default) or KMS with a caller-supplied key
- Lifecycle policy: expire untagged images after N days, cap total tagged images at N
- Mutable image tags (suitable for dev; see notes for production guidance)

## Usage

```hcl
module "ecr_api" {
  source          = "../../../modules/ecr"
  repository_name = "iss-api"
  tags = {
    environment = "dev"
    app         = "iss-tracker"
  }
}

module "ecr_poller" {
  source          = "../../../modules/ecr"
  repository_name = "iss-poller"
  tags = {
    environment = "dev"
    app         = "iss-tracker"
  }
}
```

### With KMS encryption

```hcl
module "ecr_api" {
  source           = "../../../modules/ecr"
  repository_name  = "iss-api"
  encryption_type  = "KMS"
  kms_key_arn      = "arn:aws:kms:us-east-2:123456789012:key/mrk-abc123"
}
```

### Overriding lifecycle defaults

```hcl
module "ecr_api" {
  source                        = "../../../modules/ecr"
  repository_name               = "iss-api"
  untagged_image_retention_days = 3
  max_tagged_images             = 10
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `repository_name` | Name of the ECR repository | `string` | — | yes |
| `encryption_type` | Encryption type: `AES256` or `KMS` | `string` | `"AES256"` | no |
| `kms_key_arn` | ARN of the KMS key. Required when `encryption_type = "KMS"` | `string` | `null` | no |
| `untagged_image_retention_days` | Days before untagged images are expired | `number` | `7` | no |
| `max_tagged_images` | Maximum number of tagged images to retain | `number` | `20` | no |
| `tags` | Tags to apply to the repository | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| `repository_url` | Full URL of the repository (used in `docker push`) |
| `repository_arn` | ARN of the repository |
| `repository_name` | Name of the repository |

## Notes

**Mutable vs immutable tags:** This module uses `MUTABLE` image tags, which allows overwriting an existing tag (e.g. `latest`) on push. This is practical for iterative development but means a tag does not guarantee a specific image digest. In production, `IMMUTABLE` tags are recommended — every push must use a unique tag, preventing accidental overwrites and making deployments fully auditable by tag.

**Lifecycle policy rule priority:** ECR evaluates lifecycle rules in ascending priority order. Rule 1 (untagged expiry) runs before rule 2 (tagged image cap). Both rules are always applied — there is no conditional logic based on environment.

**Image scanning:** `scan_on_push = true` triggers a Basic scan on every push. Basic scanning uses the open-source Clair engine and reports OS-level CVEs. For deeper scanning (language packages, enhanced CVE data), ECR Enhanced Scanning can be enabled at the registry level — this is not configured by this module.