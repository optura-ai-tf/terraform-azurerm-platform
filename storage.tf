# ===== Logging Storage Account =====

# Managed Identity for logging storage encryption
resource "azurerm_user_assigned_identity" "storage_logging_encryption" {
  count               = var.enable_cmk && var.storage_logging_enabled ? 1 : 0
  name                = "${var.project_name}${var.environment}-logging-encryption"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.region

  tags = merge(
    local.common_tags,
    {
      Purpose = "Storage logging encryption"
    }
  )
}

# Grant logging storage identity access to Key Vault keys
resource "azurerm_role_assignment" "kv_crypto_storage_logging" {
  count                = var.enable_cmk && var.storage_logging_enabled ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.storage_logging_encryption[0].principal_id
}

resource "azurerm_storage_account" "logging" {
  count = var.storage_logging_enabled ? 1 : 0

  name                            = var.storage_logging_account_name != null ? var.storage_logging_account_name : "${var.project_name}${var.environment}logging"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.region
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Customer-managed key encryption
  dynamic "identity" {
    for_each = var.enable_cmk ? [1] : []
    content {
      type = "UserAssigned"
      identity_ids = [
        azurerm_user_assigned_identity.storage_logging_encryption[0].id
      ]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.enable_cmk ? [1] : []
    content {
      key_vault_key_id          = azurerm_key_vault_key.storage_logging[0].id
      user_assigned_identity_id = azurerm_user_assigned_identity.storage_logging_encryption[0].id
    }
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name    = var.storage_logging_account_name != null ? var.storage_logging_account_name : "${var.project_name}${var.environment}logging"
      Purpose = "Logging storage"
    }
  )

  depends_on = [
    azurerm_role_assignment.kv_crypto_storage_logging
  ]
}

resource "azurerm_storage_container" "logging" {
  count = var.storage_logging_enabled ? 1 : 0

  name                  = "logs"
  storage_account_id    = azurerm_storage_account.logging[0].id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "logging" {
  count = var.storage_logging_enabled ? 1 : 0

  storage_account_id = azurerm_storage_account.logging[0].id

  rule {
    name    = "logging-lifecycle"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = var.storage_logging_lifecycle.transition_to_cool_days
        tier_to_archive_after_days_since_modification_greater_than = var.storage_logging_lifecycle.transition_to_archive_days
        delete_after_days_since_modification_greater_than          = var.storage_logging_lifecycle.expiration_days
      }
    }
  }
}

# ===== General Storage Account =====

# Managed Identity for general storage encryption
resource "azurerm_user_assigned_identity" "storage_general_encryption" {
  count               = var.enable_cmk && var.storage_general_enabled ? 1 : 0
  name                = "${var.project_name}${var.environment}-storage-encryption"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.region

  tags = merge(
    local.common_tags,
    {
      Purpose = "Storage general encryption"
    }
  )
}

# Grant general storage identity access to Key Vault keys
resource "azurerm_role_assignment" "kv_crypto_storage_general" {
  count                = var.enable_cmk && var.storage_general_enabled ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.storage_general_encryption[0].principal_id
}

resource "azurerm_storage_account" "storage" {
  count = var.storage_general_enabled ? 1 : 0

  name                            = var.storage_general_account_name != null ? var.storage_general_account_name : "${var.project_name}${var.environment}storage"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.region
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Customer-managed key encryption
  dynamic "identity" {
    for_each = var.enable_cmk ? [1] : []
    content {
      type = "UserAssigned"
      identity_ids = [
        azurerm_user_assigned_identity.storage_general_encryption[0].id
      ]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.enable_cmk ? [1] : []
    content {
      key_vault_key_id          = azurerm_key_vault_key.storage_general[0].id
      user_assigned_identity_id = azurerm_user_assigned_identity.storage_general_encryption[0].id
    }
  }

  blob_properties {
    versioning_enabled = var.storage_general_versioning

    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name    = var.storage_general_account_name != null ? var.storage_general_account_name : "${var.project_name}${var.environment}storage"
      Purpose = "General storage"
    }
  )

  depends_on = [
    azurerm_role_assignment.kv_crypto_storage_general
  ]
}

resource "azurerm_storage_container" "storage" {
  count = var.storage_general_enabled ? 1 : 0

  name                  = "data"
  storage_account_id    = azurerm_storage_account.storage[0].id
  container_access_type = "private"
}

# Documents container — colocated on the general storage account because
# the documents stack is the primary consumer on Azure today. Sits
# alongside the generic `data` container.
resource "azurerm_storage_container" "documents" {
  count = var.storage_general_enabled ? 1 : 0

  name                  = "documents"
  storage_account_id    = azurerm_storage_account.storage[0].id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "storage" {
  count = var.storage_general_enabled && var.storage_general_lifecycle_enabled ? 1 : 0

  storage_account_id = azurerm_storage_account.storage[0].id

  rule {
    name    = "storage-lifecycle"
    enabled = true

    # Scoped to the `data` container only. The `documents` container is
    # colocated on the same account but holds persistent documents that
    # must not be tiered or auto-deleted by this rule.
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["data/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
        delete_after_days_since_modification_greater_than       = 90
      }
    }
  }
}

# Private endpoint + privatelink DNS zone for the blob endpoint. Lets
# in-cluster traffic resolve <account>.blob.core.windows.net to the PE's
# private IP and stay on the Azure backbone (no NAT egress, no internet
# hop). The storage account itself remains publicly reachable — auth is
# the gate — so external clients (CI, ops laptops) still work.
#
# Disable via `storage_general_private_endpoint_enabled = false` when
# `create_vnet = false` and your environment manages
# privatelink.blob.core.windows.net centrally (Azure rejects multiple
# zone links of the same name on a single VNet).

resource "azurerm_private_dns_zone" "blob" {
  count               = var.storage_general_enabled && var.storage_general_private_endpoint_enabled ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count                 = var.storage_general_enabled && var.storage_general_private_endpoint_enabled ? 1 : 0
  name                  = "blob-${local.name_prefix}-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_endpoint" "storage_blob" {
  count               = var.storage_general_enabled && var.storage_general_private_endpoint_enabled ? 1 : 0
  name                = "pe-${local.name_prefix}-storage-blob"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.region
  subnet_id           = local.aks_subnet_id

  private_service_connection {
    name                           = "psc-${local.name_prefix}-storage-blob"
    private_connection_resource_id = azurerm_storage_account.storage[0].id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }

  tags = local.common_tags
}
