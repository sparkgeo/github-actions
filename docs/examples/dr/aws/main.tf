# Reference OpenTofu for the DR check (docs/dr-checklist.md). Every control in
# policies/dr passes here; tests/dr-check/run.sh scans this directory and fails
# on any finding, so it stays correct as the pack changes. Tier A as written;
# a Tier B stack can drop the replication, Multi-AZ and copy_action parts.
# CKV_AWS_21 versioning (Tier B) and CKV_AWS_144 cross-region replication (Tier A).
resource "aws_s3_bucket" "data" {
  bucket = "app-data"
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "replica" {
  bucket = "app-data-replica"
}

resource "aws_s3_bucket_versioning" "replica" {
  bucket = aws_s3_bucket.replica.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_replication_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  role   = "arn:aws:iam::123456789012:role/replication"
  rule {
    id     = "dr"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "replica" {
  bucket = aws_s3_bucket.replica.id
  role   = "arn:aws:iam::123456789012:role/replication"
  rule {
    id     = "back"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.data.arn
      storage_class = "STANDARD"
    }
  }
}

# CKV_AWS_133 retention (Tier B), CKV_AWS_157 Multi-AZ (Tier A), SPK_DR_1 in a backup selection (Tier B).
resource "aws_db_instance" "main" {
  identifier              = "app"
  engine                  = "postgres"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  multi_az                = true
  backup_retention_period = 7
}

# CKV_AWS_28 and SPK_DR_3 point-in-time recovery (Tier B).
resource "aws_dynamodb_table" "sessions" {
  name         = "sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
}

# CKV_AWS_134 automatic snapshots (Tier B).
resource "aws_elasticache_cluster" "cache" {
  cluster_id               = "app"
  engine                   = "redis"
  node_type                = "cache.t4g.micro"
  num_cache_nodes          = 1
  snapshot_retention_limit = 7
}

# SPK_DR_2 in a backup selection (Tier B).
resource "aws_efs_file_system" "shared" {
  creation_token = "app-shared"
}

# CKV_AWS_166 vault encrypted with a customer KMS key (Tier B).
resource "aws_backup_vault" "main" {
  name        = "app"
  kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/abc"
}

# SPK_DR_4 lifecycle.delete_after and a copy_action to a vault in another region (Tier A).
resource "aws_backup_plan" "main" {
  name = "app"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 * * ? *)"
    lifecycle {
      delete_after = 35
    }
    copy_action {
      destination_vault_arn = "arn:aws:backup:us-east-1:123456789012:backup-vault:app-dr"
      lifecycle {
        delete_after = 35
      }
    }
  }
}

resource "aws_backup_selection" "main" {
  iam_role_arn = "arn:aws:iam::123456789012:role/backup"
  name         = "app"
  plan_id      = aws_backup_plan.main.id
  resources = [
    aws_db_instance.main.arn,
    aws_efs_file_system.shared.arn,
  ]
}
