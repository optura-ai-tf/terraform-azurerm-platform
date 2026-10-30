# User Node Pools (support, application, and any future pools e.g. gpu)
# Every var.node_groups key except "system", which is the cluster's inline
# default_node_pool (see aks.tf) and is NOT managed here.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = local.user_pools

  name                        = each.key
  temporary_name_for_rotation = local.rotation_names[each.key]
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.main.id
  vm_size                     = each.value.vm_size
  zones                       = var.availability_zones

  auto_scaling_enabled = each.value.min_size != each.value.max_size
  min_count            = each.value.min_size != each.value.max_size ? each.value.min_size : null
  max_count            = each.value.min_size != each.value.max_size ? each.value.max_size : null
  node_count           = each.value.min_size != each.value.max_size ? null : each.value.min_size

  # Node pool configuration
  mode            = "User"
  os_type         = "Linux"
  os_disk_type    = "Managed"
  os_disk_size_gb = each.value.disk_size

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
