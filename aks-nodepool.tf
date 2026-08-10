# User Node Pools (support, application, and any future pools e.g. gpu)
# Keyed by var.user_node_pools. The system pool is the cluster's inline
# default_node_pool (see aks.tf) and is NOT managed here.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = var.user_node_pools

  name                        = each.key
  temporary_name_for_rotation = each.value.temporary_name_for_rotation
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.main.id
  vm_size                     = each.value.vm_size
  zones                       = var.availability_zones

  # Auto-scaling configuration
  auto_scaling_enabled = true
  min_count            = each.value.min_count
  max_count            = each.value.max_count

  # Node pool configuration
  mode            = "User"
  os_type         = "Linux"
  os_disk_type    = "Managed"
  os_disk_size_gb = each.value.os_disk_size_gb

  # VNet integration
  vnet_subnet_id = local.aks_subnet_id

  # Labels for workload targeting; node-pool is always the map key
  node_labels = merge(each.value.labels, { "node-pool" = each.key })

  # Taints rendered to Azure's "key=value:Effect" string form
  node_taints = [for t in each.value.taints : "${t.key}=${t.value}:${t.effect}"]

  # Upgrade settings
  upgrade_settings {
    max_surge = "33%"
  }

  tags = local.common_tags
}
