# Managed Identity for ACR encryption
resource "azurerm_user_assigned_identity" "acr_encryption" {
  count               = var.enable_cmk && var.registry_enabled && var.acr_sku == "Premium" ? 1 : 0
  name                = "${local.resource_names.acr}-encryption"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = merge(
    local.common_tags,
    {
      Purpose = "ACR encryption"
    }
  )
}

# Grant ACR identity access to Key Vault keys
resource "azurerm_role_assignment" "kv_crypto_acr" {
  count                = var.enable_cmk && var.registry_enabled && var.acr_sku == "Premium" ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.acr_encryption[0].principal_id
}

# Grant ACR identity access to Key Vault secrets (for credential sets)
resource "azurerm_role_assignment" "kv_secrets_acr" {
  count                = var.enable_cmk && var.registry_enabled && var.acr_sku == "Premium" ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.acr_encryption[0].principal_id
}

# Azure Container Registry
resource "azurerm_container_registry" "main" {
  count               = var.registry_enabled ? 1 : 0
  name                = local.resource_names.acr
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.acr_sku
  admin_enabled       = false

  # Public network access
  public_network_access_enabled = var.acr_public_network_enabled

  # Zone redundancy (Premium SKU only)
  zone_redundancy_enabled = var.acr_sku == "Premium" ? var.acr_zone_redundancy_enabled : false

  # Customer-managed key encryption (Premium SKU only)
  dynamic "encryption" {
    for_each = var.enable_cmk && var.acr_sku == "Premium" ? [1] : []
    content {
      key_vault_key_id   = azurerm_key_vault_key.acr[0].id
      identity_client_id = azurerm_user_assigned_identity.acr_encryption[0].client_id
    }
  }

  # Identity for encryption
  dynamic "identity" {
    for_each = var.enable_cmk && var.acr_sku == "Premium" ? [1] : []
    content {
      type = "UserAssigned"
      identity_ids = [
        azurerm_user_assigned_identity.acr_encryption[0].id
      ]
    }
  }

  tags = local.common_tags

  depends_on = [
    azurerm_role_assignment.kv_crypto_acr
  ]
}

# Credential set for upstream registry (if cache enabled)
resource "azurerm_container_registry_token_password" "upstream" {
  count                       = var.registry_enabled && var.enable_registry_cache ? 1 : 0
  container_registry_token_id = azurerm_container_registry_token.upstream[0].id

  password1 {
    expiry = timeadd(timestamp(), "8760h") # 1 year
  }
}

resource "azurerm_container_registry_token" "upstream" {
  count                   = var.registry_enabled && var.enable_registry_cache ? 1 : 0
  name                    = "upstream-cache-token"
  container_registry_name = azurerm_container_registry.main[0].name
  resource_group_name     = azurerm_resource_group.main.name
  scope_map_id            = azurerm_container_registry_scope_map.upstream[0].id
}

resource "azurerm_container_registry_scope_map" "upstream" {
  count                   = var.registry_enabled && var.enable_registry_cache ? 1 : 0
  name                    = "upstream-scope-map"
  container_registry_name = azurerm_container_registry.main[0].name
  resource_group_name     = azurerm_resource_group.main.name

  actions = [
    "repositories/*/content/read",
    "repositories/*/content/write"
  ]
}

# Note: ACR Cache Rules are currently in preview and may require Azure CLI
# The azurerm provider doesn't fully support cache rules yet
# This is a placeholder for when the feature becomes GA

# Microsoft Defender for Containers (if enabled)
resource "azurerm_security_center_subscription_pricing" "container_registry" {
  count         = var.enable_defender_for_containers ? 1 : 0
  tier          = "Standard"
  resource_type = "ContainerRegistry"
}
