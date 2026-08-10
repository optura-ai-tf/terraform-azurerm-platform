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

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
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
    azurerm_role_assignment.kv_admin_current_user
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
    azurerm_role_assignment.kv_admin_current_user
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
    azurerm_role_assignment.kv_admin_current_user
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
    azurerm_role_assignment.kv_admin_current_user
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
    azurerm_role_assignment.kv_admin_current_user
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
