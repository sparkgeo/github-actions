terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "fixture"
  location = "westus2"
  tags = {
    owner       = "team-platform"
    project     = "fixture"
    environment = "dev"
    data-class  = "internal"
    exposure    = "internal"
  }
}
