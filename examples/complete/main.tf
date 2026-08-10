# Complete example: a production-shaped invocation of the Azure platform module.
# Mirrors a typical dev workspace — Teleport access, a managed PostgreSQL core
# database, and the standard three-tier node-pool layout.
#
# Fill in the `[REPLACE]` placeholders below with your own values before
# `terraform apply`; other values are sizing/architecture defaults.

module "platform" {
  source = "../../"

  # Azure subscription. Supply your own; export TF_VAR_subscription_id to avoid
  # committing it (az account show --query id -o tsv).
  subscription_id = "[REPLACE]"

  environment  = "dev"
  region       = "eastus2"
  project_name = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

  tags = {
    CostCenter  = "Engineering"
    Owner       = "Platform Team"
    Environment = "dev"
  }

  # Azure AD group for cluster admins.
  aks_admin_group_name = "[REPLACE]"

  # The system pool is the cluster's inline default_node_pool.
  system_node_pool = {
    node_count = 2
    vm_size    = "Standard_D2s_v3"
  }

  # User-mode pools, keyed by name. workload-type labels drive nodeSelectors.
  user_node_pools = {
    support = {
      vm_size                     = "Standard_D2s_v3"
      min_count                   = 1
      max_count                   = 3
      os_disk_size_gb             = 128
      temporary_name_for_rotation = "supprttmp"
      labels                      = { "workload-type" = "support" }
    }
    application = {
      vm_size                     = "Standard_D4s_v3"
      min_count                   = 1
      max_count                   = 5
      os_disk_size_gb             = 256
      temporary_name_for_rotation = "apptmp"
      labels                      = { "workload-type" = "application" }
    }
  }

  # Application Gateway autoscaling bounds.
  appgw_capacity_min = 1
  appgw_capacity_max = 3

  # App Gateway frontend. The module default is now "private" (no public IP),
  # which needs the EnableApplicationGatewayNetworkIsolation subscription feature
  # and use-private-ip ingress annotations. This getting-started example opts
  # into a public frontend for simplicity; set appgw_frontend_type = "private"
  # (with appgw_private_ip_address for BYO subnets) for private mode.
  appgw_frontend_type = "public"

  # Managed PostgreSQL (enabled by default).
  postgresql_sku_name   = "GP_Standard_D2s_v3"
  postgresql_ha_enabled = false

  # Zero-trust kubectl and database access via a Teleport agent.
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
}
