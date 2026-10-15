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
  default_tags {
    tags = {
      owner       = "team-platform"
      project     = "fixture"
      environment = "dev"
      data-class  = "internal"
      exposure    = "internal"
    }
  }
}

resource "aws_sns_topic" "events" {
  name = "fixture-events"
}
