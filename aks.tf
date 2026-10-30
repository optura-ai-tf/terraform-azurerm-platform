# Data source for Azure AD admin group (only used if group ID not provided directly)
data "azuread_group" "aks_admins" {
  count            = var.aks_admin_group_id == null ? 1 : 0
  display_name     = var.aks_admin_group_name
  security_enabled = true
}

locals {
  system_pool = var.node_groups["system"]
  user_pools  = { for k, v in var.node_groups : k => v if k != "system" }
  # Keep in sync with the node_groups rotation name validation.
  rotation_names = {
    for k, v in var.node_groups : k => coalesce(v.temporary_name_for_rotation, "${substr(k, 0, 9)}tmp")
  }
  network_data_plane = coalesce(var.network_data_plane, var.pod_cidr != null ? "cilium" : "azure")
}

# Azure Kubernetes Service Cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = local.resource_names.aks
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.resource_names.aks
  kubernetes_version  = var.kubernetes_version

  # Standard tier for 99.95% SLA with Availability Zones
  sku_tier = "Standard"

  # Private cluster configuration
  private_cluster_enabled = var.private_cluster_enabled

  # System node pool (tainted for system workloads only)
  default_node_pool {
    name                        = "system"
    temporary_name_for_rotation = local.rotation_names["system"]
    vm_size                     = local.system_pool.vm_size
    # Fixed size when min_size == max_size. Otherwise autoscaled, and node_count
    # is left to the autoscaler (null) so its changes don't show as drift.
    auto_scaling_enabled         = local.system_pool.min_size != local.system_pool.max_size
    min_count                    = local.system_pool.min_size != local.system_pool.max_size ? local.system_pool.min_size : null
    max_count                    = local.system_pool.min_size != local.system_pool.max_size ? local.system_pool.max_size : null
    node_count                   = local.system_pool.min_size != local.system_pool.max_size ? null : local.system_pool.min_size
    zones                        = var.availability_zones
    type                         = "VirtualMachineScaleSets"
    os_disk_type                 = "Managed"
    os_disk_size_gb              = local.system_pool.disk_size
    only_critical_addons_enabled = true

    # VNet integration
    vnet_subnet_id = local.aks_subnet_id

    # Labels
    node_labels = merge(local.system_pool.labels, { "node-pool" = "system" })

    upgrade_settings {
      max_surge = "10%"
    }

    tags = local.common_tags
  }

  # Network configuration - Azure CNI
  network_profile {
    network_plugin = "azure"
    # Overlay when pod_cidr is set: pods take IPs from pod_cidr (never routed,
    # SNAT'd to the node IP), so the AKS subnet only holds nodes and endpoints.
    # Overlay also runs the Cilium dataplane by default, which enforces
    # network policy (see local.network_data_plane).
    network_plugin_mode = var.pod_cidr != null ? "overlay" : null
    network_data_plane  = local.network_data_plane
    network_policy      = local.network_data_plane
    pod_cidr            = var.pod_cidr
    load_balancer_sku   = "standard"
    outbound_type       = var.aks_outbound_type
    # Service CIDR for ClusterIP services (must not overlap with VNet)
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  # System-assigned managed identity
  identity {
    type = "SystemAssigned"
  }

  # Enable OIDC issuer for Workload Identity
  oidc_issuer_enabled = true

  # Enable Workload Identity for federated credentials
  workload_identity_enabled = true

  # Customer-managed key encryption for OS disks
  disk_encryption_set_id = var.enable_cmk ? azurerm_disk_encryption_set.aks[0].id : null

  # Azure AD integration
  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled     = true
    admin_group_object_ids = [var.aks_admin_group_id != null ? var.aks_admin_group_id : data.azuread_group.aks_admins[0].object_id]
  }

  # Needs to be enabled to allow using certificates
  # for authentication in terraform cloud
  local_account_disabled = false

  # API Server access configuration (only when not private)
  dynamic "api_server_access_profile" {
    for_each = !var.private_cluster_enabled && length(var.api_server_authorized_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_cidrs
    }
  }

  # RBAC enabled
  role_based_access_control_enabled = true

  # Application Gateway Ingress Controller addon
  ingress_application_gateway {
    gateway_id = azurerm_application_gateway.main.id
  }

  # Maintenance window
  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 3, 4]
    }
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].upgrade_settings
    ]

    # The variable validation only covers a module-created VNet; this checks a BYO one.
    precondition {
      condition = var.pod_cidr == null || var.create_vnet ? true : alltrue([
        for v in data.azurerm_virtual_network.existing[0].address_space :
        cidrhost("${cidrhost(v, 0)}/${split("/", var.pod_cidr)[1]}", 0) != cidrhost(var.pod_cidr, 0) &&
        cidrhost("${cidrhost(var.pod_cidr, 0)}/${split("/", v)[1]}", 0) != cidrhost(v, 0)
      ])
      error_message = "pod_cidr must not overlap the existing VNet's address space."
    }
  }

  # Note: Role assignments depend on this cluster's AGIC identity
  # Terraform handles dependency order automatically via implicit dependencies
  depends_on = [
    azurerm_application_gateway.main
  ]
}
