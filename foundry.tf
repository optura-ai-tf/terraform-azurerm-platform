# Azure AI Foundry — gated by var.foundry_enabled. Provisions a Foundry
# (AIServices) account and a private endpoint into the AKS subnet. Model
# deployments (Claude, GPT, …) are created manually via the Foundry portal.
# The intent service workload identity is managed generically via
# var.workload_identities (azure/workload-identity.tf).

locals {
  foundry_location     = coalesce(var.foundry_location, azurerm_resource_group.main.location)
  foundry_account_name = "${local.name_prefix}-foundry"

  # DNS zone the Foundry private endpoint registers into, resolved across three
  # distinct states:
  #   - BYO DNS (managed externally): use the supplied external zone ID, or null
  #     → the PE omits its DNS zone group and central policy/DINE registers it.
  #   - Terraform-managed DNS: use the locally created zone (foundry_enabled).
  #   - Foundry disabled: null (the PE is never created).
  # Split into two locals so the precedence reads top-to-bottom instead of as a
  # nested ternary.
  foundry_dns_external       = var.foundry_private_dns_managed_externally || var.private_dns_zones_managed_externally
  _foundry_local_dns_zone_id = var.foundry_enabled && !local.foundry_dns_external ? azurerm_private_dns_zone.foundry[0].id : null
  foundry_dns_zone_id        = local.foundry_dns_external ? try(coalesce(var.foundry_existing_private_dns_zone_id, var.existing_private_dns_zone_ids.foundry), null) : local._foundry_local_dns_zone_id
  foundry_policy_dns         = local.foundry_dns_external && try(coalesce(var.foundry_existing_private_dns_zone_id, var.existing_private_dns_zone_ids.foundry), null) == null
}

# ===== Private DNS for AIServices accounts =====

resource "azurerm_private_dns_zone" "foundry" {
  count               = (var.foundry_enabled && !local.foundry_dns_external) ? 1 : 0
  name                = "privatelink.services.ai.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  count = (var.foundry_enabled && !local.foundry_dns_external) ? 1 : 0
  # Name preserves the original module-era convention (`foundry-${name_prefix}-vnet-link`)
  # so existing deployments don't see a destroy+recreate. `name` is ForceNew
  # on this resource — a rename would unlink the zone from the VNet during
  # the replacement and break DNS resolution for the Foundry private endpoint.
  name                  = "foundry-${local.name_prefix}-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.foundry[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false

  tags = local.common_tags
}

# ===== Foundry account =====

resource "azurerm_cognitive_account" "foundry" {
  count               = var.foundry_enabled ? 1 : 0
  name                = local.foundry_account_name
  resource_group_name = azurerm_resource_group.main.name
  location            = local.foundry_location

  kind     = "AIServices"
  sku_name = var.foundry_sku_name

  # ForceNew — set per-env to match the account's created-with value so adopting
  # environments don't force a replace (see var docs). Default false.
  project_management_enabled = var.foundry_project_management_enabled

  # Data-plane auth. Default (foundry_local_auth_enabled=false) is AAD-only —
  # the intent UAMI (via workload_identities) is the sole caller. Set the var
  # true to also accept key-based (API-key) auth; the private endpoint and
  # network_acls Deny still gate network reachability either way.
  local_auth_enabled = var.foundry_local_auth_enabled

  # Force traffic through the private endpoint.
  public_network_access_enabled = false

  # Custom subdomain is required for AAD auth and the Foundry data-plane URL.
  custom_subdomain_name = local.foundry_account_name

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Cushion the race between azurerm_cognitive_account marking the resource
# complete and ARM finishing provisioning. Without this, private endpoint
# creation can fail with AccountProvisioningStateInvalid on the first apply.
resource "time_sleep" "wait_for_foundry_account" {
  count           = var.foundry_enabled ? 1 : 0
  depends_on      = [azurerm_cognitive_account.foundry]
  create_duration = "30s"
}

# ===== Private endpoint =====

resource "azurerm_private_endpoint" "foundry" {
  count               = var.foundry_enabled && !local.foundry_policy_dns ? 1 : 0
  name                = "pe-${local.foundry_account_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = local.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${local.foundry_account_name}"
    private_connection_resource_id = azurerm_cognitive_account.foundry[0].id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }

  private_dns_zone_group {
    name                 = "foundry-dns-zone-group"
    private_dns_zone_ids = [local.foundry_dns_zone_id]
  }

  depends_on = [time_sleep.wait_for_foundry_account]

  tags = local.common_tags
}

# See azurerm_private_endpoint.acr_policy_dns: policy-managed DNS zone group.
resource "azurerm_private_endpoint" "foundry_policy_dns" {
  count               = var.foundry_enabled && local.foundry_policy_dns ? 1 : 0
  name                = "pe-${local.foundry_account_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = local.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${local.foundry_account_name}"
    private_connection_resource_id = azurerm_cognitive_account.foundry[0].id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }

  lifecycle {
    ignore_changes = [private_dns_zone_group]
  }

  depends_on = [time_sleep.wait_for_foundry_account]

  tags = local.common_tags
}
