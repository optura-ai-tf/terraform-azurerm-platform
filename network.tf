# Data source for existing VNet (when create_vnet = false)
data "azurerm_virtual_network" "existing" {
  count               = var.create_vnet ? 0 : 1
  name                = var.existing_vnet_name
  resource_group_name = var.existing_vnet_rg
}

# Virtual Network (when create_vnet = true)
resource "azurerm_virtual_network" "main" {
  count               = var.create_vnet ? 1 : 0
  name                = local.resource_names.vnet
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# Local to get VNet ID regardless of creation mode
locals {
  vnet_id   = var.create_vnet ? azurerm_virtual_network.main[0].id : data.azurerm_virtual_network.existing[0].id
  vnet_name = var.create_vnet ? azurerm_virtual_network.main[0].name : data.azurerm_virtual_network.existing[0].name
  vnet_rg   = var.create_vnet ? azurerm_resource_group.main.name : var.existing_vnet_rg

  # Subnet IDs normalized across creation modes (BYO subnets when create_vnet = false)
  aks_subnet_id        = var.create_vnet ? azurerm_subnet.aks[0].id : var.existing_aks_subnet_id
  appgw_subnet_id      = var.create_vnet ? azurerm_subnet.appgw[0].id : var.existing_appgw_subnet_id
  postgresql_subnet_id = var.create_vnet ? (var.postgresql_enabled ? azurerm_subnet.postgresql[0].id : null) : var.existing_postgresql_subnet_id
}

# AKS Subnet
resource "azurerm_subnet" "aks" {
  count                = var.create_vnet ? 1 : 0
  name                 = "snet-aks-${var.environment}"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.aks_subnet_address_prefix]

  # Service endpoints for ACR and Storage
  service_endpoints = [
    "Microsoft.ContainerRegistry",
    "Microsoft.Storage"
  ]

  depends_on = [
    azurerm_virtual_network.main
  ]
}

# Application Gateway Subnet
resource "azurerm_subnet" "appgw" {
  count                = var.create_vnet ? 1 : 0
  name                 = "snet-appgw-${var.environment}"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.appgw_subnet_address_prefix]

  # AGIC with Azure CNI Overlay and a private-only App Gateway both require the
  # subnet delegated to Microsoft.Network/applicationGateways.
  dynamic "delegation" {
    for_each = var.pod_cidr != null || local.appgw_private_enabled ? [1] : []
    content {
      name = "appgw-delegation"
      service_delegation {
        name    = "Microsoft.Network/applicationGateways"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }

  depends_on = [
    azurerm_virtual_network.main
  ]
}

# PostgreSQL Subnet (delegated to PostgreSQL service)
resource "azurerm_subnet" "postgresql" {
  count                = (var.create_vnet && var.postgresql_enabled) ? 1 : 0
  name                 = "snet-postgresql-${var.environment}"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.postgresql_subnet_address_prefix]

  # Delegate subnet to PostgreSQL Flexible Server
  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }

  depends_on = [
    azurerm_virtual_network.main
  ]
}

# Guard: when bringing your own VNet (create_vnet = false), the existing subnet IDs
# must be provided so the normalizing locals above resolve to real subnet resource IDs.
resource "terraform_data" "byo_subnet_guard" {
  lifecycle {
    precondition {
      condition     = var.create_vnet || (var.existing_aks_subnet_id != null && var.existing_appgw_subnet_id != null && (!var.postgresql_enabled || var.existing_postgresql_subnet_id != null))
      error_message = "create_vnet=false requires existing_aks_subnet_id, existing_appgw_subnet_id, and (when postgresql_enabled=true) existing_postgresql_subnet_id to be set to full ARM subnet resource IDs."
    }
  }
}
