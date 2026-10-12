terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "aws_sns_topic" "events" {
  name = "fixture-events"
  tags = {
    owner = "team-platform"
  }
}
