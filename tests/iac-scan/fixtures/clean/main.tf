# Minimal resource with no failing checkov policies, with one intentional
# suppression to prove the inline skip syntax is honoured.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_sns_topic" "events" {
  # checkov:skip=CKV_AWS_26:Fixture topic carries no sensitive payloads
  name = "fixture-events"
}
