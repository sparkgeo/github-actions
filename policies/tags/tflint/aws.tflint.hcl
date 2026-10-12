# tflint configuration for the Sparkgeo tagging standard on AWS
# (policies/tags/standard.yml). The tflint composite runs this as a second
# pass with `--only aws_resource_missing_tags` when require-tags is on, so the
# consuming repo's own .tflint.hcl is left untouched. provider default_tags
# satisfy the rule.
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["owner", "project", "environment", "data-class"]
}
