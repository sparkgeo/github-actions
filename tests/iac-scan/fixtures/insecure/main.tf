# Deliberately misconfigured resources for AWS and GCP. Used by
# tests/iac-scan/run.sh to prove the gate blocks on both providers.
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

resource "aws_s3_bucket" "public" {
  bucket = "fixture-public-bucket"
}

resource "aws_s3_bucket_public_access_block" "public" {
  bucket                  = aws_s3_bucket.public.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_security_group" "open" {
  name = "fixture-open"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "google_storage_bucket" "public" {
  name     = "fixture-public-bucket"
  location = "US"
}

resource "google_storage_bucket_iam_member" "public" {
  bucket = google_storage_bucket.public.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
