# tflint configuration for the Sparkgeo tagging standard on Azure
# (policies/tags/standard.yml); see aws.tflint.hcl. azurerm has no provider
# level default tags, so every taggable resource must carry the keys itself.
plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

rule "azurerm_resource_missing_tags" {
  enabled = true
  tags    = ["owner", "project", "environment", "data-class"]
}
