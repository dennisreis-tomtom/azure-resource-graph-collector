resource "azurerm_resource_group" "rg" {
  location = var.location
  name     = var.resource_group
}

resource "azurerm_storage_account" "sa" {
  account_replication_type = "LRS"
  account_tier             = "Standard"
  location                 = var.location
  name                     = "sa${format("%.22s", replace(var.function_app_identifier, "-", ""))}"
  resource_group_name      = azurerm_resource_group.rg.name
}

resource "azurerm_storage_container" "sacontainer" {
  name                  = "contents"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.function_app_identifier}-log"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "appinsight" {
  application_type    = "web"
  location            = var.location
  name                = "${var.function_app_identifier}-appinsights"
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id

  tags = merge(
    var.tags,
    {
      # https://github.com/terraform-providers/terraform-provider-azurerm/issues/1303
      "hidden-link:${azurerm_resource_group.rg.id}/providers/Microsoft.Web/sites/${var.function_app_identifier}-function-app" = "Resource"
  })
}

resource "azurerm_service_plan" "service_plan" {
  location            = var.location
  name                = "${var.function_app_identifier}-service-plan"
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "S2"
}

resource "azurerm_linux_function_app" "function_app" {
  depends_on                  = [azurerm_storage_container.sacontainer]
  location                    = var.location
  name                        = "${var.function_app_identifier}-function-app"
  service_plan_id             = azurerm_service_plan.service_plan.id
  resource_group_name         = azurerm_resource_group.rg.name
  storage_account_name        = azurerm_storage_account.sa.name
  storage_account_access_key  = azurerm_storage_account.sa.primary_access_key
  functions_extension_version = "~4"

  site_config {
    always_on = true
    application_stack {
      python_version = "3.10"
    }
    application_insights_connection_string = "InstrumentationKey=${azurerm_application_insights.appinsight.instrumentation_key};IngestionEndpoint=https://${var.location}-0.in.applicationinsights.azure.com/"
    application_insights_key               = azurerm_application_insights.appinsight.instrumentation_key
  }

  app_settings = {
    "LOKI_USERNAME"                 = var.loki_authentication.username
    "LOKI_PASSWORD"                 = var.loki_authentication.password
    "LOKI_ENDPOINT"                 = var.loki_endpoint_url
    "LOKI_LABEL_NAMES"              = var.loki_label_names
    "RESOURCE_GRAPH_QUERY_IDS"      = var.resource_graph_query_ids
    "STORAGE_ACCOUNT_CONNECTION"    = azurerm_storage_account.sa.primary_connection_string
    "CONTAINER_NAME"                = azurerm_storage_container.sacontainer.name
    "ENABLE_LOKI_PUBLISHER"         = var.enable_loki_publisher
    "ENABLE_AZURE_BLOB_PUBLISHER"   = var.enable_azure_blob_publisher
    "TABLE_NAME"                    = var.azure_table_name
    "USER_ASSIGNED_IDENTITY_APP_ID" = data.azurerm_user_assigned_identity.identity.client_id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = data.azurerm_user_assigned_identity.identity[*].id
  }
}

resource "azurerm_monitor_diagnostic_setting" "logs" {
  name                       = "application-logs"
  target_resource_id         = azurerm_linux_function_app.function_app.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "FunctionAppLogs"
    retention_policy {
      enabled = false
    }
  }

  metric {
    category = "AllMetrics"
    retention_policy {
      enabled = false
    }
  }
}
