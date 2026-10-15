# Retention and residency in infrastructure code

SecOps plan Step 36 Standard (issue #120): "scheduled deletion jobs enforcing the retention table with logged evidence", and data residency from Step 17. `retention.yml` at the repository root is the retention table; `retention-check.yml` proves on every PR that the infrastructure implements it, and the merged diff is the evidence. The stores are the same ids as the asset inventory (#115) and `ropa.yml` (#119); the retention values must agree with the RoPA. Start from [`examples/retention.yml`](examples/retention.yml).

## `retention.yml`

```yaml
version: 1
defaults:
  allowed_regions: [ca-central-1, us-west-2]
  backup_expiry_grace: 35d
stores:
  aws_s3_bucket.ingest:         {retention: 90d, mechanism: lifecycle}
  aws_cloudwatch_log_group.api: {retention: 30d, mechanism: retention_in_days}
  aws_rds_cluster.app:          {retention: 35d, mechanism: backup_retention, residency: [ca-central-1]}
  aws_dynamodb_table.sessions:  {retention: 7d,  mechanism: ttl, ttl_attribute: expires_at}
```

Keys are OpenTofu addresses (`type.name`, module prefix included) or, for CDK, the CloudFormation logical id or the `aws:cdk:path` metadata of the resource. `retention` is `<n>d|m|y` or `until-<event>` (then only presence is checked). `residency` narrows `defaults.allowed_regions` for one store.

## Mechanisms per store type

| Store | Mechanism | What the policy reads (OpenTofu / CloudFormation) | Policy |
|---|---|---|---|
| S3 bucket | `lifecycle` | `aws_s3_bucket_lifecycle_configuration` referencing the bucket: an enabled rule whose `expiration.days` equals the declared days; with `aws_s3_bucket_versioning` enabled, `noncurrent_version_expiration.noncurrent_days` too. CFN: `LifecycleConfiguration.Rules[].ExpirationInDays`, `NoncurrentVersionExpiration.NoncurrentDays`, `VersioningConfiguration.Status` | `SPK_RET_2` |
| CloudWatch log group | `retention_in_days` | `retention_in_days` / `RetentionInDays` equal to the declared days; `0` or absent never expires | `SPK_RET_3` |
| RDS cluster or instance | `backup_retention` | `backup_retention_period` / `BackupRetentionPeriod` equal to the declared days (the DR check #93 sets the minimum, this sets the exact value) | `SPK_RET_4` |
| DynamoDB table | `ttl` | `ttl { enabled, attribute_name }` / `TimeToLiveSpecification` enabled, on `ttl_attribute` when declared; the application writes the expiry timestamp | `SPK_RET_5` |
| AWS Backup plan | (defaults) | every rule's `lifecycle.delete_after` / `Lifecycle.DeleteAfterDays` is at most the longest declared retention plus `backup_expiry_grace`; absent means backups never expire | `SPK_RET_6` |
| any of the above | (entry) | every store in the table exists in the plan; every resource tagged `data-class: confidential` or `restricted` of these types has an entry | `SPK_RET_1` |
| any sensitive resource | (residency) | region of the resource (provider config or the CDK manifest environment) in `allowed_regions` or the store's `residency`; S3 replication destinations and backup `copy_action` vault regions too | `SPK_RES_1` |

Not covered and tracked per project: application-level deletion jobs for rows inside a database (the DSAR harness #122 tests erasure), object stores outside AWS, and Glacier vault locks.

## Backup expiry position

Backups keep data past the record's retention; that is expected, and bounded. The position: a backup may outlive the declared retention of the longest-retained store it contains by at most `defaults.backup_expiry_grace` (35 days here: one monthly cycle plus a week of restore window). Set it per repository in `retention.yml`; `SPK_RET_6` enforces it against every `aws_backup_plan` rule, and the DR check (#93, `SPK_DR_4`) keeps the floor. Document any longer legal hold as a per-store `until-legal-hold` entry with the reason.

## Levels

| Finding | `none` | `mismatch` (default) | `all` |
|---|---|---|---|
| mismatch (`SPK_RET_2` to `SPK_RET_6`), entry missing or store absent (`SPK_RET_1`) | warn | fail | fail |
| residency (`SPK_RES_1`), unknown region, uncheckable mechanism | warn | warn | fail |

## GCP and Azure

The table format is the same; the policies cover AWS types only. Equivalents to add when a repository needs them: GCS `lifecycle_rule { condition { age } action { type = "Delete" } }`, Cloud Logging bucket `retention_days`, Cloud SQL `backup_configuration.transaction_log_retention_days` and `backup_retention_settings`, Bigtable and Firestore TTL policies; Azure Storage `lifecycle management policy` (`azurerm_storage_management_policy` `delete_after_days_since_modification_greater_than`), Log Analytics `retention_in_days`, Azure SQL `short_term_retention_policy`, Cosmos DB `default_ttl`. Residency: `location` on the resource.

## Consuming

```yaml
jobs:
  retention:
    permissions:
      contents: read
      pull-requests: write
    uses: sparkgeo/github-actions/.github/workflows/retention-check.yml@<SHA>
    with:
      actions-ref: <SHA>   # same SHA as above
      directory: infra
      plan-command: tofu init -input=false && tofu plan -input=false -out plan.out && tofu show -json plan.out > plan.json
      plan-json: plan.json
      # or, for CDK:  plan-command: npx cdk synth   /  template: cdk.out/Prod.template.json
```

`plan-command` runs in `directory` with the caller's credentials (OIDC via `aws-oidc-auth` in a previous step of the caller, or a plan committed by another job).
