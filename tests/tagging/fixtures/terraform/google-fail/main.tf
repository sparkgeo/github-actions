terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "fixture"
  default_labels = {
    owner = "team-platform"
  }
}

resource "google_storage_bucket" "assets" {
  name     = "fixture-assets"
  location = "US"
}
