# AI-services pass fixture (issue #189): private, encrypted, logged, guarded.
provider "aws" {
  region = "us-west-2"
}

resource "aws_kms_key" "ai" {
  description = "ai services"
}

resource "aws_bedrock_guardrail" "g" {
  name                      = "g"
  blocked_input_messaging   = "blocked"
  blocked_outputs_messaging = "blocked"
}

resource "aws_bedrockagent_agent" "a" {
  agent_name                  = "a"
  agent_resource_role_arn     = "arn:aws:iam::123456789012:role/bedrock-agent"
  foundation_model            = "anthropic.claude-3-sonnet-20240229-v1:0"
  customer_encryption_key_arn = aws_kms_key.ai.arn
  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.g.guardrail_id
    guardrail_version    = "DRAFT"
  }
}

resource "aws_bedrock_model_invocation_logging_configuration" "l" {
  logging_config {
    embedding_data_delivery_enabled = true
    image_data_delivery_enabled     = true
    text_data_delivery_enabled      = true
    cloudwatch_config {
      log_group_name = "/aws/bedrock/invocations"
      role_arn       = "arn:aws:iam::123456789012:role/bedrock-logging"
    }
  }
}

resource "aws_sagemaker_notebook_instance" "n" {
  name                   = "n"
  role_arn               = "arn:aws:iam::123456789012:role/sagemaker"
  instance_type          = "ml.t3.medium"
  kms_key_id             = aws_kms_key.ai.arn
  subnet_id              = "subnet-0123456789abcdef0"
  security_groups        = ["sg-0123456789abcdef0"]
  direct_internet_access = "Disabled"
  root_access            = "Disabled"
  instance_metadata_service_configuration {
    minimum_instance_metadata_service_version = "2"
  }
}

resource "google_vertex_ai_endpoint" "e" {
  name         = "e"
  display_name = "e"
  location     = "us-central1"
  predict_request_response_logging_config {
    enabled       = true
    sampling_rate = 1
    bigquery_destination {
      output_uri = "bq://project.dataset.table"
    }
  }
}

resource "azurerm_key_vault_key" "openai" {
  name         = "openai"
  key_vault_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]
}

resource "azurerm_cognitive_account" "openai" {
  name                               = "openai"
  location                           = "westeurope"
  resource_group_name                = "rg"
  kind                               = "OpenAI"
  sku_name                           = "S0"
  public_network_access_enabled      = false
  local_auth_enabled                 = false
  outbound_network_access_restricted = true
  fqdns                              = ["api.openai.azure.com"]
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account_customer_managed_key" "openai" {
  cognitive_account_id = azurerm_cognitive_account.openai.id
  key_vault_key_id     = azurerm_key_vault_key.openai.id
}

resource "azurerm_monitor_diagnostic_setting" "openai" {
  name                       = "openai"
  target_resource_id         = azurerm_cognitive_account.openai.id
  log_analytics_workspace_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/w"
  enabled_log {
    category = "Audit"
  }
  enabled_log {
    category = "RequestResponse"
  }
}
