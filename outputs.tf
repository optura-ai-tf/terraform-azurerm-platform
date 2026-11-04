# ===== Resource Group =====

output "resource_group_name" {
  description = "Name of the main resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "ID of the main resource group"
  value       = azurerm_resource_group.main.id
}

output "resource_group_location" {
  description = "Location of the main resource group"
  value       = azurerm_resource_group.main.location
}

# ===== Network Outputs =====

output "network_id" {
  description = "ID of the virtual network"
  value       = local.vnet_id
}

output "network_name" {
  description = "Name of the virtual network"
  value       = local.vnet_name
}

output "cluster_subnet_id" {
  description = "ID of the cluster subnet"
  value       = local.aks_subnet_id
}

output "ingress_subnet_id" {
  description = "ID of the ingress/Application Gateway subnet"
  value       = local.appgw_subnet_id
}

# ===== AKS Cluster Outputs =====

output "cluster_name" {
  description = "Name of the Kubernetes cluster"
  value       = azurerm_kubernetes_cluster.main.name
}

output "cluster_id" {
  description = "ID of the Kubernetes cluster"
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_endpoint" {
  description = "Endpoint/FQDN of the Kubernetes cluster"
  value       = azurerm_kubernetes_cluster.main.fqdn
}

output "cluster_node_resource_group" {
  description = "Auto-created resource group containing AKS node VMs"
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "cluster_kube_config_raw" {
  description = "Raw kubeconfig for the Kubernetes cluster"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Command to configure kubectl access"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

# ===== Container Registry Outputs =====

output "registry_name" {
  description = "Name of the container registry"
  value       = var.registry_enabled ? azurerm_container_registry.main[0].name : null
}

output "registry_id" {
  description = "ID of the container registry"
  value       = var.registry_enabled ? azurerm_container_registry.main[0].id : null
}

output "registry_url" {
  description = "Login server URL for the container registry"
  value       = var.registry_enabled ? azurerm_container_registry.main[0].login_server : null
}

# ===== Application Gateway =====

output "application_gateway_id" {
  description = "ID of the Application Gateway"
  value       = azurerm_application_gateway.main.id
}

output "application_gateway_name" {
  description = "Name of the Application Gateway"
  value       = azurerm_application_gateway.main.name
}

output "application_gateway_public_ip" {
  description = "Public IP address of the Application Gateway (null when appgw_frontend_type = \"private\")"
  value       = one(azurerm_public_ip.appgw[*].ip_address)
}

output "application_gateway_fqdn" {
  description = "FQDN of the Application Gateway public IP (null when appgw_frontend_type = \"private\")"
  value       = one(azurerm_public_ip.appgw[*].fqdn)
}

output "application_gateway_private_ip" {
  description = "Private frontend IP address of the Application Gateway (null when appgw_frontend_type = \"public\")"
  value       = one([for f in azurerm_application_gateway.main.frontend_ip_configuration : f.private_ip_address if f.name == "appgw-frontend-ip-private"])
}

# ===== Database Outputs =====

# Map outputs — one entry per named server in var.databases.
output "database_endpoints" {
  description = "FQDN of each named PostgreSQL Flexible Server, keyed by database name"
  value       = { for k, s in azurerm_postgresql_flexible_server.main : k => s.fqdn }
}

output "database_server_ids" {
  description = "Resource ID of each named PostgreSQL Flexible Server, keyed by database name (for diagnostic settings)"
  value       = { for k, s in azurerm_postgresql_flexible_server.main : k => s.id }
}

output "database_names" {
  description = "Initial database name for each named PostgreSQL server"
  value       = { for k, d in azurerm_postgresql_flexible_server_database.main : k => d.name }
}

output "database_admin_usernames" {
  description = "Administrator username for each named PostgreSQL server"
  value       = { for k, s in azurerm_postgresql_flexible_server.main : k => s.administrator_login }
  sensitive   = true
}

output "database_admin_passwords" {
  description = "Administrator password for each named PostgreSQL server"
  value       = { for k, p in random_password.postgresql_admin : k => p.result }
  sensitive   = true
}

# Singular outputs — backward-compatible aliases that resolve to the "core" entry.
output "database_server_name" {
  description = "Name of the primary (core) database server"
  value       = try(azurerm_postgresql_flexible_server.main["core"].name, null)
}

output "database_endpoint" {
  description = "FQDN of the primary (core) database server"
  value       = try(azurerm_postgresql_flexible_server.main["core"].fqdn, null)
}

output "database_address" {
  description = "Address of the primary (core) database server"
  value       = try(azurerm_postgresql_flexible_server.main["core"].fqdn, null)
}

output "database_port" {
  description = "Port of the database server"
  value       = var.postgresql_enabled ? 5432 : null
}

output "database_name" {
  description = "Name of the primary (core) database"
  value       = try(azurerm_postgresql_flexible_server_database.main["core"].name, null)
}

output "database_admin_username" {
  description = "Administrator username for the primary (core) database"
  value       = try(azurerm_postgresql_flexible_server.main["core"].administrator_login, null)
  sensitive   = true
}

output "database_admin_password" {
  description = "Administrator password for the primary (core) database"
  value       = try(random_password.postgresql_admin["core"].result, null)
  sensitive   = true
}

# ===== Key Vault =====

output "key_vault_name" {
  description = "Name of the Azure Key Vault"
  value       = var.enable_cmk ? azurerm_key_vault.main[0].name : null
}

output "key_vault_id" {
  description = "ID of the Azure Key Vault"
  value       = var.enable_cmk ? azurerm_key_vault.main[0].id : null
}

output "key_vault_uri" {
  description = "URI of the Azure Key Vault"
  value       = var.enable_cmk ? azurerm_key_vault.main[0].vault_uri : null
}

# ===== Foundry =====

output "foundry_account_id" {
  description = "Resource ID of the Azure AI Foundry account (null when foundry_enabled = false)"
  value       = var.foundry_enabled ? azurerm_cognitive_account.foundry[0].id : null
}

# ===== Storage Outputs =====

output "logging_storage_name" {
  description = "Name of the logging storage"
  value       = var.storage_logging_enabled ? azurerm_storage_account.logging[0].name : null
}

output "logging_storage_id" {
  description = "ID of the logging storage"
  value       = var.storage_logging_enabled ? azurerm_storage_account.logging[0].id : null
}

output "logging_storage_region" {
  description = "Region of the logging storage"
  value       = var.storage_logging_enabled ? azurerm_storage_account.logging[0].location : null
}

output "general_storage_name" {
  description = "Name of the general storage"
  value       = var.storage_general_enabled ? azurerm_storage_account.storage[0].name : null
}

output "general_storage_id" {
  description = "ID of the general storage"
  value       = var.storage_general_enabled ? azurerm_storage_account.storage[0].id : null
}

output "general_storage_region" {
  description = "Region of the general storage"
  value       = var.storage_general_enabled ? azurerm_storage_account.storage[0].location : null
}

# ===== Workload Identities =====
#
# One entry per configured workload identity (the keys of var.workload_identities
# that survive gating — logging, documents, documents-processing, and any
# operator-defined workloads). Replaces the former per-identity outputs
# (logging_storage_*, general_storage_role_id/client_id, documents_uami_*,
# documents_processing_uami_*).
#
# Consumers:
#   - client_id    -> Workload Identity ServiceAccount annotation
#                     (azure.workload.identity/client-id)
#   - principal_id  -> AAD object ID, for RBAC role assignments from other repos
#   - id            -> ARM resource ID of the UAMI
output "workload_identities" {
  description = "Map of configured workload identities keyed by name, each { id, client_id, principal_id }."
  value = {
    for k, wi in azurerm_user_assigned_identity.workload : k => {
      id           = wi.id
      client_id    = wi.client_id
      principal_id = wi.principal_id
    }
  }
}

# ===== Access Configuration =====

output "access_mode" {
  description = "Current K8s API access mode"
  value       = var.access_mode
}

output "api_endpoint_access_type" {
  description = "Type of access to the K8s API endpoint"
  value       = "Private only - requires ${var.access_mode} connectivity"
}

output "teleport_agent_status" {
  description = "Command to check Teleport agent status"
  value       = var.access_mode == "teleport" ? "kubectl -n teleport-agent logs -l app=teleport-kube-agent" : "Not deployed (access_mode=${var.access_mode})"
}

# ===== Teleport =====

output "teleport_db_agent_client_id" {
  description = "Client ID of managed identity for Teleport database agent"
  value       = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? azurerm_user_assigned_identity.teleport_db_agent[0].client_id : null
}

# ===== Terraform Cloud Agent =====

output "tfc_agent_status" {
  description = "Terraform Cloud Agent deployment status"
  value = var.tfc_agent_enabled ? {
    enabled   = true
    namespace = "terraform-cloud"
  } : { enabled = false }
}

output "cluster_access_mode" {
  description = "Current cluster API access configuration"
  value = {
    private_cluster = var.private_cluster_enabled
    access_method   = var.private_cluster_enabled ? "tfc-agent" : "direct"
  }
}
