# Backup and DR readiness checklist

The checklist behind [`dr-check-tofu.yml`](../.github/workflows/dr-check-tofu.yml) (issue #95, plan Steps 8 and 19). It gives every check in [`policies/dr/`](../policies/dr) a control and a minimum tier, fixes how a finding is suppressed, and lists the controls no scanner can verify. `tests/dr-check/run.sh` fails when the table below and the policy ids drift apart, and when [`docs/examples/dr/`](examples/dr) stops scanning clean.

## Tiers

Pick one tier per repository and record it in that repository's README (see [Manual controls](#manual-controls)). The tier decides which checks are required and which may be suppressed.

| Tier | RTO | RPO | Meaning |
|---|---|---|---|
| A | 1 hour | 15 minutes | Client-facing or revenue-bearing with state that cannot be rebuilt. Backups, replication and a second region are required. |
| B | 24 hours | 24 hours | State that must survive but can wait a day: internal tools, analytics stores, staging with real data. Backups in one region. |
| C | best effort | not applicable | Rebuilt from code and public inputs. No backup control is required; keep the IaC and the pipelines that rebuild it. |

A check is required at its minimum tier and every tier above it. Tier A requires every check; Tier B requires the Tier B rows; Tier C requires none.

## Checks

The `Check` column is the id checkov reports and the id to pass in `strict-checks`. The `SPK_DR_*` rows are the graph policies in `policies/dr/spk_dr_*.yaml`; the rest are built-in checkov checks listed in `policies/dr/checks.txt`.

| Check | Control | Resource | Tier |
|---|---|---|---|
| `CKV_AWS_21` | Versioning enabled so deleted or overwritten objects can be restored | `aws_s3_bucket` | B |
| `CKV_AWS_144` | Cross-region replication to a bucket in another region | `aws_s3_bucket` | A |
| `CKV_AWS_133` | Automated backups with `backup_retention_period` of at least 7 days | `aws_db_instance`, `aws_rds_cluster` | B |
| `CKV_AWS_157` | Multi-AZ standby for automatic failover | `aws_db_instance` | A |
| `CKV_AWS_28` | Point-in-time recovery enabled | `aws_dynamodb_table` | B |
| `CKV_AWS_134` | Automatic snapshots with `snapshot_retention_limit` of at least 7 days | `aws_elasticache_cluster` | B |
| `CKV_AWS_166` | Backup vault encrypted with a customer-managed KMS key | `aws_backup_vault` | B |
| `CKV_GCP_78` | Object versioning enabled | `google_storage_bucket` | B |
| `CKV_GCP_14` | Automated backups enabled | `google_sql_database_instance` | B |
| `CKV_AZURE_206` | Geo-redundant replication (`GRS`, `GZRS` or `RAGRS`) | `azurerm_storage_account` | A |
| `CKV_AZURE_94` | Geo-redundant backup enabled | `azurerm_mysql_server`, `azurerm_mysql_flexible_server` | A |
| `CKV_AZURE_102` | Geo-redundant backup enabled | `azurerm_postgresql_server` | A |
| `CKV_AZURE_129` | Geo-redundant backup enabled | `azurerm_mariadb_server` | A |
| `CKV_AZURE_136` | Geo-redundant backup enabled | `azurerm_postgresql_flexible_server` | A |
| `CKV_AZURE_230` | `Standard` or `Premium` SKU so the cache has a replica | `azurerm_redis_cache` | A |
| `CKV_AZURE_111` | Soft delete so purged secrets and keys can be recovered | `azurerm_key_vault` | B |
| `SPK_DR_1` | Instance or cluster ARN listed in an `aws_backup_selection` | `aws_db_instance`, `aws_rds_cluster` | B |
| `SPK_DR_2` | File system ARN listed in an `aws_backup_selection` | `aws_efs_file_system` | B |
| `SPK_DR_3` | Table ARN listed in an `aws_backup_selection`, or point-in-time recovery enabled | `aws_dynamodb_table` | B |
| `SPK_DR_4` | Every rule sets `lifecycle.delete_after` and copies to a vault in another region | `aws_backup_plan` | A |

### `strict-checks` by tier

The advisory run always comments on every finding. The strict run fails the job on the ids in `strict-checks`; set it from the repository's tier.

```yaml
# Tier B
strict-checks: CKV_AWS_21,CKV_AWS_133,CKV_AWS_28,CKV_AWS_134,CKV_AWS_166,CKV_GCP_78,CKV_GCP_14,CKV_AZURE_111,SPK_DR_1,SPK_DR_2,SPK_DR_3
# Tier A: the Tier B list plus
#   CKV_AWS_144,CKV_AWS_157,CKV_AZURE_206,CKV_AZURE_94,CKV_AZURE_102,CKV_AZURE_129,CKV_AZURE_136,CKV_AZURE_230,SPK_DR_4
# Tier C: leave strict-checks empty; the advisory comment still appears.
```

## Suppressing a finding

A finding may be suppressed for two reasons only, and the reason goes in the comment so the report can tell them apart. A `checkov:skip` without a reason is listed under "Suppressions without a reason" in the PR comment.

1. The control is above the repository's tier. Start the reason with the tier:

   ```hcl
   resource "aws_s3_bucket" "logs" {
     # checkov:skip=CKV_AWS_144:Tier C, logs are rebuilt from CloudTrail
     bucket = "app-logs"
   }
   ```

2. The control applies but cannot be met. Open a security exception with the `security-exception` issue form (issue #81) and start the reason with the issue number:

   ```hcl
   # checkov:skip=CKV_AWS_157:exception #123, single-AZ until the client approves the Multi-AZ cost
   ```

For CDK stacks, `dr-check-cdk.yml` (issue #94) reports the cdk-nag NIST 800-53 rev 5 rules in `policies/dr/cdk-nag-rules.txt`. cdk-nag 3 replaced `NagSuppressions` with CDK's own acknowledgements; use the same reason text:

```ts
Validations.of(cacheBucket).acknowledge({
  id: 'NIST.800.53.R5::NIST.800.53.R5-S3BucketVersioningEnabled',
  reason: 'Tier C: cache objects are rebuilt from the source bucket on a miss',
});
```

An acknowledgement whose reason is under 20 characters is reported in the PR comment. On a rule in `strict-rules`, it does not count. Starter apps for TypeScript and Python are in [`docs/examples/dr/cdk`](examples/dr/cdk).

## Manual controls

Checkov sees the IaC, not what was exercised. These controls are confirmed by hand and their evidence recorded in a `## Disaster recovery` section of the repository README: the tier, and one row per item below with a link and a date.

| Item | Tier | Evidence | Cadence |
|---|---|---|---|
| Tier recorded in the README with the RTO and RPO it commits to | A, B, C | README section | On change |
| State backend bucket is versioned and, for Tier A, replicated | A, B, C | Backend configuration | On setup |
| Restore from backup into a scratch account or region, and the time it took | A, B | Issue or run log with the date | A: quarterly. B: yearly |
| Region failover exercised end to end (DNS, routing, secrets) | A | Runbook with the date it was last run | Yearly |
| Secrets and parameters present in the DR region | A | Replication configuration | On change |
| Backup vault access policy denies delete, or Vault Lock is on | A | Policy in the IaC | On setup |

## Examples

[`docs/examples/dr/aws/main.tf`](examples/dr/aws/main.tf) is a Tier A stack that passes every AWS check; the comment above each resource names the checks it satisfies. GCP and Azure examples are not written yet; the `Resource` column and the remediation text in the PR comment give the attribute to set.
