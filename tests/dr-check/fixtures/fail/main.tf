# Every DR control missed: one finding per curated AWS check and custom policy.
resource "aws_s3_bucket" "data" {
  bucket = "app-data"
}

resource "aws_db_instance" "main" {
  identifier              = "app"
  engine                  = "postgres"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  backup_retention_period = 0
}

resource "aws_dynamodb_table" "sessions" {
  name         = "sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_elasticache_cluster" "cache" {
  cluster_id      = "app"
  engine          = "redis"
  node_type       = "cache.t4g.micro"
  num_cache_nodes = 1
}

resource "aws_efs_file_system" "shared" {
  creation_token = "app-shared"
}

resource "aws_backup_vault" "main" {
  name = "app"
}

resource "aws_backup_plan" "main" {
  name = "app"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 * * ? *)"
  }
}

resource "aws_s3_bucket" "logs" {
  # checkov:skip=CKV_AWS_21
  # checkov:skip=CKV_AWS_144:Tier C, logs are rebuilt from CloudTrail (docs/dr-checklist.md)
  bucket = "app-logs"
}
