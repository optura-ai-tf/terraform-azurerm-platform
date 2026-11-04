# AKS kubelet identity -> ACR pull access
resource "azurerm_role_assignment" "aks_acr_pull" {
  count                = var.registry_enabled ? 1 : 0
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.main[0].id
}

# AGIC addon identity -> Application Gateway Contributor
resource "azurerm_role_assignment" "agic_appgw" {
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Contributor"
  scope                = azurerm_application_gateway.main.id
}

# AGIC addon identity -> Application Gateway subnet Network Contributor
resource "azurerm_role_assignment" "agic_subnet" {
  count                = var.create_vnet ? 1 : 0
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Network Contributor"
  scope                = local.appgw_subnet_id
}

# AGIC addon identity -> Resource Group Reader
resource "azurerm_role_assignment" "agic_rg_reader" {
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Reader"
  scope                = azurerm_resource_group.main.id
}

# AGIC addon identity -> Managed Identity Operator on App Gateway identity
# This allows AGIC to assign the user-assigned identity to the App Gateway
resource "azurerm_role_assignment" "agic_identity_operator" {
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Managed Identity Operator"
  scope                = azurerm_user_assigned_identity.appgw.id
}

# AKS cluster identity -> Network Contributor on AKS subnet (if we created the VNet)
# System-assigned: the principal exists only after the cluster, so grant afterwards.
resource "azurerm_role_assignment" "aks_network" {
  count                = var.create_vnet && var.aks_identity_id == null ? 1 : 0
  principal_id         = local.aks_identity_principal_id
  role_definition_name = "Network Contributor"
  scope                = local.aks_subnet_id
}

# User-assigned: grant before the cluster exists; AKS checks it at create time.
# A custom API zone needs VNet scope: AKS links the zone to the VNet (join/action).
resource "azurerm_role_assignment" "aks_network_uai" {
  count                = var.create_vnet && var.aks_identity_id != null ? 1 : 0
  principal_id         = local.aks_uai_principal_id
  role_definition_name = "Network Contributor"
  scope                = !contains(["System", "None"], coalesce(var.aks_private_dns_zone_id, "System")) ? local.vnet_id : local.aks_subnet_id
}

# AKS cluster identity -> Reader on Disk Encryption Set
# Required for AKS control plane to manage disk encryption
resource "azurerm_role_assignment" "aks_des_reader" {
  count                = var.enable_cmk ? 1 : 0
  principal_id         = local.aks_identity_principal_id
  role_definition_name = "Reader"
  scope                = azurerm_disk_encryption_set.aks[0].id
}

# AKS kubelet identity -> Reader on Disk Encryption Set
# Required for kubelet to attach encrypted disks to nodes (PVC operations)
resource "azurerm_role_assignment" "kubelet_des_reader" {
  count                = var.enable_cmk ? 1 : 0
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name = "Reader"
  scope                = azurerm_disk_encryption_set.aks[0].id
}

# ===== Teleport Database Agent Workload Identity =====

resource "azurerm_user_assigned_identity" "teleport_db_agent" {
  count               = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? 1 : 0
  name                = "id-teleport-db-agent-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = local.common_tags
}

resource "azurerm_federated_identity_credential" "teleport_db_agent" {
  count                     = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? 1 : 0
  name                      = "teleport-db-agent"
  user_assigned_identity_id = azurerm_user_assigned_identity.teleport_db_agent[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:teleport-agent:teleport-kube-agent"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "teleport" {
  for_each            = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? var.databases : {}
  server_name         = azurerm_postgresql_flexible_server.main[each.key].name
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.teleport_db_agent[0].principal_id
  principal_name      = azurerm_user_assigned_identity.teleport_db_agent[0].name
  principal_type      = "ServicePrincipal"
}
