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

  # Node pools, keyed by name. "system" is the cluster's inline system pool.
  # workload-type labels drive nodeSelectors.
  node_groups = {
    system = {
      vm_size  = "Standard_D2s_v3"
      min_size = 2
      max_size = 2
      labels   = { "workload-type" = "system" }
    }
    support = {
      vm_size                     = "Standard_D2s_v3"
      min_size                    = 1
      max_size                    = 3
      disk_size                   = 128
      temporary_name_for_rotation = "supprttmp"
      labels                      = { "workload-type" = "support" }
    }
    application = {
      vm_size                     = "Standard_D4s_v3"
      min_size                    = 1
      max_size                    = 5
      disk_size                   = 256
      temporary_name_for_rotation = "apptmp"
      labels                      = { "workload-type" = "application" }
    }
  }

  # Application Gateway autoscaling bounds.
  appgw_capacity_min = 1
  appgw_capacity_max = 3

  # Everything is private by default: private App Gateway frontend (needs the
  # EnableApplicationGatewayNetworkIsolation subscription feature and
  # use-private-ip ingress annotations), private AKS API, and storage / Key
  # Vault behind private endpoints. The API is created in this same apply, so
  # this getting-started example opts into a public, CIDR-restricted API.
  # For a private API, run Terraform from inside a pre-built VNet instead.
  private_cluster_enabled     = false
  api_server_authorized_cidrs = ["[REPLACE]"] # your runner's egress CIDR(s)

  # Key Vault (enable_cmk defaults to true) is deny-all. Allow the runner
  # through, or run inside the VNet and rely on the private endpoint.
  key_vault_allowed_ip_ranges = ["[REPLACE]"]

  # Managed PostgreSQL (enabled by default).
  postgresql_sku_name   = "GP_Standard_D2s_v3"
  postgresql_ha_enabled = false

  # Zero-trust kubectl and database access via a Teleport agent.
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
}
