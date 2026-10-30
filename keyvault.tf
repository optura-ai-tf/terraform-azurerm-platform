# Azure Key Vault for storing secrets and encryption keys
resource "azurerm_key_vault" "main" {
  count                       = var.enable_cmk ? 1 : 0
  name                        = local.resource_names.key_vault
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "premium"
  enabled_for_disk_encryption = true

  # Use RBAC for access control (recommended over access policies)
  rbac_authorization_enabled = true

  # Soft delete and purge protection
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # Private by default: deny public traffic. AzureServices lets the CMK
  # consumers (Storage, disk encryption set, PostgreSQL, ACR) through;
  # Terraform reaches the data plane via the private endpoint below or an
  # allowed IP range.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.key_vault_allowed_ip_ranges
  }

  tags = local.common_tags
}

# Grant current user/service principal full access to manage secrets during terraform apply
resource "azurerm_role_assignment" "kv_admin_current_user" {
  count                = var.enable_cmk ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ===== Private endpoint =====

resource "azurerm_private_dns_zone" "key_vault" {
  count               = var.enable_cmk && var.key_vault_private_endpoint_enabled ? 1 : 0
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  count                 = var.enable_cmk && var.key_vault_private_endpoint_enabled ? 1 : 0
  name                  = "kv-${local.name_prefix}-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count               = var.enable_cmk && var.key_vault_private_endpoint_enabled ? 1 : 0
  name                = "pe-${local.resource_names.key_vault}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = local.aks_subnet_id

  private_service_connection {
    name                           = "psc-${local.resource_names.key_vault}"
    private_connection_resource_id = azurerm_key_vault.main[0].id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault[0].id]
  }

  tags = local.common_tags
}

# Keys are written over the data plane, so wait for the admin role, the
# private endpoint, and its DNS record to settle before creating them.
resource "time_sleep" "key_vault_ready" {
  count           = var.enable_cmk ? 1 : 0
  create_duration = "30s"

  depends_on = [
    azurerm_role_assignment.kv_admin_current_user,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
}

# ===== Encryption Keys =====

# Key for AKS disk encryption
resource "azurerm_key_vault_key" "aks_disk" {
  count        = var.enable_cmk ? 1 : 0
  name         = "aks-disk-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "AKS disk encryption"
    }
  )

  depends_on = [
    time_sleep.key_vault_ready
  ]
}

# Key for PostgreSQL encryption
resource "azurerm_key_vault_key" "postgresql" {
  count        = var.enable_cmk && var.postgresql_enabled ? 1 : 0
  name         = "postgresql-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "PostgreSQL encryption"
    }
  )

  depends_on = [
    time_sleep.key_vault_ready
  ]
}

# Key for ACR encryption
resource "azurerm_key_vault_key" "acr" {
  count        = var.enable_cmk && var.registry_enabled && var.acr_sku == "Premium" ? 1 : 0
  name         = "acr-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "ACR encryption"
    }
  )

  depends_on = [
    time_sleep.key_vault_ready
  ]
}

# Key for Storage Account encryption (logging)
resource "azurerm_key_vault_key" "storage_logging" {
  count        = var.enable_cmk && var.storage_logging_enabled ? 1 : 0
  name         = "storage-logging-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "Storage logging encryption"
    }
  )

  depends_on = [
    time_sleep.key_vault_ready
  ]
}

# Key for Storage Account encryption (general)
resource "azurerm_key_vault_key" "storage_general" {
  count        = var.enable_cmk && var.storage_general_enabled ? 1 : 0
  name         = "storage-general-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "Storage general encryption"
    }
  )

  depends_on = [
    time_sleep.key_vault_ready
  ]
}

# ===== Managed Identities for Encryption =====

# Managed Identity for disk encryption set
resource "azurerm_user_assigned_identity" "disk_encryption" {
  count               = var.enable_cmk ? 1 : 0
  name                = "${local.resource_names.aks}-disk-encryption"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = merge(
    local.common_tags,
    {
      Purpose = "AKS disk encryption"
    }
  )
}

# Grant disk encryption identity access to Key Vault keys
resource "azurerm_role_assignment" "kv_crypto_disk_encryption" {
  count                = var.enable_cmk ? 1 : 0
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.disk_encryption[0].principal_id
}

# Disk Encryption Set for AKS
resource "azurerm_disk_encryption_set" "aks" {
  count               = var.enable_cmk ? 1 : 0
  name                = "${local.resource_names.aks}-disk-encryption-set"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  key_vault_key_id    = azurerm_key_vault_key.aks_disk[0].id

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.disk_encryption[0].id
    ]
  }

  tags = local.common_tags

  depends_on = [
    azurerm_role_assignment.kv_crypto_disk_encryption
  ]
}
