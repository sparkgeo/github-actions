# AI-services fail fixture (issue #189): no invocation logging, no
# guardrails, no CMK, notebook on the internet with root, public OpenAI.
provider "aws" {
  region = "us-west-2"
}

resource "aws_bedrockagent_agent" "a" {
  agent_name              = "a"
  agent_resource_role_arn = "arn:aws:iam::123456789012:role/bedrock-agent"
  foundation_model        = "anthropic.claude-3-sonnet-20240229-v1:0"
}

resource "aws_sagemaker_notebook_instance" "n" {
  name                   = "n"
  role_arn               = "arn:aws:iam::123456789012:role/sagemaker"
  instance_type          = "ml.t3.medium"
  direct_internet_access = "Enabled"
}

resource "google_vertex_ai_endpoint" "e" {
  name         = "e"
  display_name = "e"
  location     = "us-central1"
}

resource "azurerm_cognitive_account" "openai" {
  name                = "openai"
  location            = "westeurope"
  resource_group_name = "rg"
  kind                = "OpenAI"
  sku_name            = "S0"
}
