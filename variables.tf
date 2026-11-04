# ===== Global Configuration =====

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, stg, uat, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "stg", "uat", "prod"], var.environment)
    error_message = "Environment must be one of: 'dev', 'stg', 'uat', or 'prod'."
  }
}

variable "region" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "optura"
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project_name))
    error_message = "Project name must be lowercase alphanumeric, 3-12 characters."
  }
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "key_vault_private_endpoint_enabled" {
  description = "Create a private endpoint + privatelink.vaultcore.azure.net DNS zone for the CMK Key Vault (enable_cmk = true), linked to the VNet. Default true. The vault firewall always denies public traffic except Azure trusted services and key_vault_allowed_ip_ranges, so Terraform must reach the vault through this endpoint or an allowed range. Set false when privatelink.vaultcore.azure.net is managed centrally."
  type        = bool
  default     = true

  validation {
    condition     = !var.enable_cmk || var.key_vault_private_endpoint_enabled || length(var.key_vault_allowed_ip_ranges) > 0
    error_message = "With enable_cmk = true, Terraform must reach the Key Vault data plane: keep key_vault_private_endpoint_enabled = true or set key_vault_allowed_ip_ranges."
  }
}

variable "key_vault_allowed_ip_ranges" {
  description = "Public IPs/CIDRs allowed through the CMK Key Vault firewall (e.g. a Terraform runner outside the VNet). Give a single IP as a bare address (1.2.3.4): Key Vault rejects /31 and /32. Default empty: public traffic is denied except Azure trusted services."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.key_vault_allowed_ip_ranges : !endswith(r, "/31") && !endswith(r, "/32")])
    error_message = "Key Vault rejects /31 and /32 CIDRs in key_vault_allowed_ip_ranges. Give single IPs as bare addresses (e.g. 1.2.3.4)."
  }
}

variable "key_vault_soft_delete_retention_days" {
  description = "Soft-delete retention in days for the CMK Key Vault (enable_cmk = true). Default 7. Azure sets it only when the vault is created; changing it later fails, so set the final value before the first apply."
  type        = number
  default     = 7

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "enable_cmk" {
  description = "Use customer-managed keys (CMK) for encryption. When false, Azure uses platform-managed keys (PMK) instead — data is still AES-256 encrypted at rest, Azure just manages the key. Set to false for subscription transfers to eliminate Key Vault and encryption identity dependencies."
  type        = bool
  default     = true
}

# ===== Network Configuration =====

variable "create_vnet" {
  description = "Create new VNet (true) or use existing (false)"
  type        = bool
  default     = true
}

variable "vnet_address_space" {
  description = "Address space for VNet (only used if create_vnet=true)"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "aks_subnet_address_prefix" {
  description = "Address prefix for AKS subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "appgw_subnet_address_prefix" {
  description = "Address prefix for Application Gateway subnet"
  type        = string
  default     = "10.0.16.0/24"
}

variable "postgresql_subnet_address_prefix" {
  description = "Address prefix for PostgreSQL subnet"
  type        = string
  default     = "10.0.17.0/24"
}

variable "existing_vnet_name" {
  description = "Name of existing VNet (only used if create_vnet=false)"
  type        = string
  default     = null
}

variable "existing_vnet_rg" {
  description = "Resource group of existing VNet (only used if create_vnet=false)"
  type        = string
  default     = null
}

variable "existing_aks_subnet_id" {
  description = "Full ARM resource ID of a pre-created AKS subnet (/subscriptions/.../subnets/...). Only used if create_vnet=false. The subnet must be sized for Azure CNI and the AKS cluster identity must be granted Network Contributor on it out-of-band."
  type        = string
  default     = null

  validation {
    condition     = var.existing_aks_subnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.existing_aks_subnet_id))
    error_message = "existing_aks_subnet_id must be a full ARM subnet resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/...)."
  }
}

variable "existing_appgw_subnet_id" {
  description = "Full ARM resource ID of a pre-created Application Gateway subnet. Only used if create_vnet=false. Must be dedicated to the App Gateway and the AGIC identity must be granted Network Contributor on it out-of-band."
  type        = string
  default     = null

  validation {
    condition     = var.existing_appgw_subnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.existing_appgw_subnet_id))
    error_message = "existing_appgw_subnet_id must be a full ARM subnet resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/...)."
  }
}

variable "existing_postgresql_subnet_id" {
  description = "Full ARM resource ID of a pre-created, delegated PostgreSQL subnet. Only used if create_vnet=false, postgresql_enabled=true and postgresql_network_mode=vnet_integration. Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers and dedicated."
  type        = string
  default     = null

  validation {
    condition     = var.existing_postgresql_subnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.existing_postgresql_subnet_id))
    error_message = "existing_postgresql_subnet_id must be a full ARM subnet resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/...)."
  }
}

variable "existing_private_endpoint_subnet_id" {
  description = "Full ARM resource ID of a dedicated subnet for the module's private endpoints (ACR, Foundry, Key Vault, storage, and PostgreSQL in private_endpoint mode, one per server). Default null: they use the AKS subnet. Changing it on an existing deployment recreates the endpoints, which changes their IPs."
  type        = string
  default     = null

  validation {
    condition     = var.existing_private_endpoint_subnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.existing_private_endpoint_subnet_id))
    error_message = "existing_private_endpoint_subnet_id must be a full ARM subnet resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/...)."
  }
}

variable "private_dns_zones_managed_externally" {
  description = "When true, the module creates no private DNS zones or VNet links (blob, Key Vault, ACR, PostgreSQL, Foundry): they live centrally, e.g. in a hub subscription. Each private endpoint registers into the matching existing_private_dns_zone_ids entry, or gets no DNS zone group when that entry is null (central policy registers the record). Default false. Set it before the first apply: turning it on in an existing deployment destroys the module's zones, VNet links and A records (link the hub zones to the VNet first), and with postgresql_network_mode = \"vnet_integration\" the changed private_dns_zone_id can replace every PostgreSQL server. Run a plan first."
  type        = bool
  default     = false
}

variable "existing_private_dns_zone_ids" {
  description = "ARM resource IDs of centrally managed private DNS zones, used when private_dns_zones_managed_externally = true. blob = privatelink.blob.core.windows.net, key_vault = privatelink.vaultcore.azure.net, acr = privatelink.azurecr.io, foundry = privatelink.services.ai.azure.com, postgresql = privatelink.postgres.database.azure.com (private_endpoint mode) or a *.postgres.database.azure.com zone (vnet_integration mode, required there). The Terraform identity needs Private DNS Zone Contributor on each zone it registers into."
  type = object({
    blob       = optional(string)
    key_vault  = optional(string)
    acr        = optional(string)
    foundry    = optional(string)
    postgresql = optional(string)
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for id in values(var.existing_private_dns_zone_ids) : id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/[^/]+$", id))])
    error_message = "existing_private_dns_zone_ids entries must be full ARM private DNS zone IDs (/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/privateDnsZones/...)."
  }
  validation {
    condition     = !var.private_dns_zones_managed_externally || !var.postgresql_enabled || var.postgresql_network_mode == "private_endpoint" || var.existing_private_dns_zone_ids.postgresql != null
    error_message = "With private_dns_zones_managed_externally = true and postgresql_network_mode = \"vnet_integration\", existing_private_dns_zone_ids.postgresql is required: a VNet-integrated server needs its zone at creation."
  }
}

variable "service_cidr" {
  description = "In-cluster ClusterIP service range for AKS (Azure CNI). Must NOT overlap the VNet address space or any subnet — critical when create_vnet=false and the VNet is centrally managed."
  type        = string
  default     = "10.1.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid IPv4 CIDR (e.g. 10.1.0.0/16)."
  }
}

variable "dns_service_ip" {
  description = "Cluster DNS service IP. Must fall inside service_cidr."
  type        = string
  default     = "10.1.0.10"

  # Cross-variable validation (Terraform >= 1.9): masking dns_service_ip with
  # service_cidr's prefix length must yield service_cidr's network address —
  # i.e. dns_service_ip lies inside service_cidr. Catches the common typo of a
  # DNS IP in the wrong block (e.g. 10.2.0.10 against 10.1.0.0/16) at plan time.
  validation {
    condition = (
      can(cidrhost(var.service_cidr, 0)) &&
      can(cidrhost("${var.dns_service_ip}/${split("/", var.service_cidr)[1]}", 0)) &&
      cidrhost("${var.dns_service_ip}/${split("/", var.service_cidr)[1]}", 0) == cidrhost(var.service_cidr, 0)
    )
    error_message = "dns_service_ip must be a valid IPv4 address that falls inside service_cidr."
  }
}

variable "pod_cidr" {
  description = <<-EOT
    Pod IP range for Azure CNI Overlay (the default). Pods take IPs from this
    range instead of the AKS subnet, the range is never routed (pod egress is
    SNAT'd to the node IP), and the AKS subnet only needs to hold nodes and
    private endpoints. Each node takes a /24 from the range, so the default
    /16 fits 256 nodes. Must not overlap service_cidr, the VNet, or any
    peered / on-premises network. Set null for Azure CNI without overlay
    (pods take VNet IPs; size the AKS subnet for it).

    Set it before the first apply: changing it forces a new cluster. With
    overlay, the App Gateway subnet must be /24 or smaller and delegated to
    Microsoft.Network/applicationGateways (the module adds the delegation
    when create_vnet = true; do it yourself on a BYO subnet).
  EOT
  type        = string
  default     = "100.64.0.0/16"

  validation {
    condition     = var.pod_cidr == null || can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid IPv4 CIDR (e.g. 100.64.128.0/17)."
  }

  # Overlap check: either range contains the other's network address.
  validation {
    condition = var.pod_cidr == null ? true : (
      cidrhost("${cidrhost(var.service_cidr, 0)}/${split("/", var.pod_cidr)[1]}", 0) != cidrhost(var.pod_cidr, 0) &&
      cidrhost("${cidrhost(var.pod_cidr, 0)}/${split("/", var.service_cidr)[1]}", 0) != cidrhost(var.service_cidr, 0)
    )
    error_message = "pod_cidr must not overlap service_cidr."
  }

  validation {
    condition = var.pod_cidr == null || !var.create_vnet ? true : alltrue([
      for v in var.vnet_address_space :
      cidrhost("${cidrhost(v, 0)}/${split("/", var.pod_cidr)[1]}", 0) != cidrhost(var.pod_cidr, 0) &&
      cidrhost("${cidrhost(var.pod_cidr, 0)}/${split("/", v)[1]}", 0) != cidrhost(v, 0)
    ])
    error_message = "pod_cidr must not overlap vnet_address_space."
  }

  validation {
    condition     = var.pod_cidr == null || !var.create_vnet ? true : tonumber(split("/", var.appgw_subnet_address_prefix)[1]) >= 24
    error_message = "With pod_cidr (overlay), AGIC requires the App Gateway subnet to be /24 or smaller (appgw_subnet_address_prefix)."
  }
}

variable "network_data_plane" {
  description = "AKS network dataplane. null (default): \"cilium\" with overlay (pod_cidr set), \"azure\" without. \"cilium\": Azure CNI Powered by Cilium, eBPF dataplane without kube-proxy, Cilium network policy; requires overlay. \"azure\": legacy dataplane with Azure network policy; use it to keep overlay without Cilium. Switching azure -> cilium upgrades in place (reimages every node); cilium -> azure forces a new cluster."
  type        = string
  default     = null

  validation {
    condition     = var.network_data_plane == null ? true : contains(["azure", "cilium"], var.network_data_plane)
    error_message = "network_data_plane must be null, azure or cilium."
  }

  validation {
    condition     = var.network_data_plane != "cilium" || var.pod_cidr != null
    error_message = "network_data_plane = \"cilium\" requires Azure CNI Overlay (pod_cidr set)."
  }
}

# ===== AKS Configuration =====

variable "kubernetes_version" {
  description = "Kubernetes version. Give a minor version (for example 1.35) while aks_automatic_upgrade_channel is set; a full patch version is allowed only when it is null."
  type        = string
  default     = "1.35"

  validation {
    condition     = var.aks_automatic_upgrade_channel == null || can(regex("^\\d+\\.\\d+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.35 while aks_automatic_upgrade_channel is set. Drop the patch component, or set aks_automatic_upgrade_channel = null to pin a patch version."
  }
}

variable "aks_automatic_upgrade_channel" {
  description = "AKS automatic upgrade channel: \"patch\" (default) applies patch releases within kubernetes_version's minor version, weekly on Sunday 02:00-06:00 UTC. null turns automatic upgrades off. \"stable\" and \"rapid\" change the minor version, so Terraform would plan a downgrade; they are not accepted."
  type        = string
  default     = "patch"

  validation {
    condition     = var.aks_automatic_upgrade_channel == null || var.aks_automatic_upgrade_channel == "patch"
    error_message = "aks_automatic_upgrade_channel must be \"patch\" or null."
  }
}

# "system" is the cluster's inline default_node_pool, which azurerm requires on
# the cluster resource; every other key is a separate node pool resource.
variable "node_groups" {
  description = "AKS node pools keyed by name. \"system\" is the cluster's system pool; every other key is a user pool. A pool autoscales between min_size and max_size, or is fixed at that size when they are equal."
  type = map(object({
    vm_size                     = string
    min_size                    = number
    max_size                    = number
    disk_size                   = optional(number, 128)
    temporary_name_for_rotation = optional(string)
    labels                      = map(string)
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string # Azure expects PascalCase: NoSchedule | PreferNoSchedule | NoExecute
    })), [])
  }))
  default = {
    system = {
      vm_size   = "Standard_D2s_v6"
      min_size  = 3
      max_size  = 3
      disk_size = 128
      labels    = { "workload-type" = "system" }
    }
    support = {
      vm_size                     = "Standard_E2as_v7"
      min_size                    = 1
      max_size                    = 3
      disk_size                   = 128
      temporary_name_for_rotation = "supprttmp"
      labels                      = { "workload-type" = "support" }
    }
    application = {
      vm_size                     = "Standard_D4as_v7"
      min_size                    = 1
      max_size                    = 3
      disk_size                   = 256
      temporary_name_for_rotation = "apptmp"
      labels                      = { "workload-type" = "application" }
    }
  }

  validation {
    condition     = contains(keys(var.node_groups), "system")
    error_message = "node_groups must include a \"system\" key."
  }

  # Map keys (and temporary_name_for_rotation) become AKS node pool names, which
  # Azure restricts to lowercase alphanumeric, starting with a letter, max 12 chars.
  # Guard here so a bad name fails at plan, not mid-apply.
  validation {
    condition = alltrue([
      for k, v in var.node_groups : can(regex("^[a-z][a-z0-9]{0,11}$", k)) && (v.temporary_name_for_rotation == null || can(regex("^[a-z][a-z0-9]{0,11}$", v.temporary_name_for_rotation)))
    ])
    error_message = "Each node_groups key and its temporary_name_for_rotation must match ^[a-z][a-z0-9]{0,11}$ (lowercase alphanumeric, start with a letter, max 12 chars)."
  }

  # A rotation name that matches a pool name, or another pool's rotation name,
  # fails mid-apply. Same derivation as local.rotation_names in aks.tf.
  validation {
    condition = (
      length(distinct([
        for k, v in var.node_groups : coalesce(v.temporary_name_for_rotation, "${substr(k, 0, 9)}tmp")
      ])) == length(var.node_groups) &&
      length(setintersection(keys(var.node_groups), [
        for k, v in var.node_groups : coalesce(v.temporary_name_for_rotation, "${substr(k, 0, 9)}tmp")
      ])) == 0
    )
    error_message = "Each node_groups rotation name (temporary_name_for_rotation, or the default: the first 9 characters of the key plus \"tmp\") must be unique and must not equal any pool name. Set temporary_name_for_rotation explicitly to fix a clash."
  }

  # CLOUD_PROVIDER_GUIDE requires a workload-type label on every pool (workloads
  # target it via nodeSelector). node-pool is auto-injected from the key.
  validation {
    condition = alltrue([
      for v in values(var.node_groups) : contains(keys(v.labels), "workload-type")
    ])
    error_message = "Each node_groups entry must set a \"workload-type\" label (used by workload nodeSelectors)."
  }

  # Azure taint effects are PascalCase; a typo otherwise passes plan and fails at the API.
  validation {
    condition = alltrue([
      for v in values(var.node_groups) : alltrue([
        for t in v.taints : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
      ])
    ])
    error_message = "taint.effect must be one of: NoSchedule, PreferNoSchedule, NoExecute (Azure PascalCase)."
  }
}

variable "availability_zones" {
  description = "Availability zones for AKS nodes and the App Gateway. Azure can restrict a VM size in a zone per subscription (common on new subscriptions); check with az vm list-skus. Set before the first apply: changing it later replaces the App Gateway (only its public IP ignores zone changes)."
  type        = list(string)
  default     = ["1", "3"]
}

variable "aks_outbound_type" {
  description = "AKS egress method. \"loadBalancer\" (default) gives nodes a public egress IP on the cluster load balancer. \"userDefinedRouting\" creates no public IP: egress follows the AKS subnet's route table (e.g. 0.0.0.0/0 to a hub firewall), which must be associated with the subnet before the cluster is created, so it requires create_vnet = false (BYO subnet). Changing it on an existing cluster may force replacement."
  type        = string
  default     = "loadBalancer"
  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting"], var.aks_outbound_type)
    error_message = "aks_outbound_type must be loadBalancer or userDefinedRouting."
  }
  validation {
    condition     = var.aks_outbound_type == "loadBalancer" || !var.create_vnet
    error_message = "aks_outbound_type = \"userDefinedRouting\" requires create_vnet = false: the module-created AKS subnet has no route table."
  }
}

variable "log_analytics_workspace_id" {
  description = "Full ARM resource ID of a Log Analytics workspace. When set, AKS sends Container Insights data to it (managed identity auth). Default null: off. Diagnostic settings are left to the caller; see the resource ID outputs."
  type        = string
  default     = null

  validation {
    condition     = var.log_analytics_workspace_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.OperationalInsights/workspaces/[^/]+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a full ARM resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.OperationalInsights/workspaces/...), not the workspace GUID."
  }
}

variable "log_analytics_workspace_location" {
  description = "Region of the log_analytics_workspace_id workspace. The Container Insights data collection rule must be in the workspace's region. Defaults to the resource group location. Set it when the workspace is in another region (e.g. a central hub workspace)."
  type        = string
  default     = null
}

variable "azure_policy_enabled" {
  description = "Install the Azure Policy add-on (Gatekeeper) so Azure Policy assignments apply inside the cluster. Default false."
  type        = bool
  default     = false
}

variable "api_server_authorized_cidrs" {
  description = "Authorized CIDR blocks for API server access (only applies when private_cluster_enabled = false, empty = open)"
  type        = list(string)
  default     = []
}

variable "aks_admin_group_name" {
  description = "Azure AD group name for AKS cluster admins (ignored if aks_admin_group_id is set)"
  type        = string
  default     = "AKS Terraform Admins"
}

variable "aks_admin_group_id" {
  description = "Azure AD group Object ID for AKS cluster admins (bypasses group lookup, useful when SP lacks Group.Read.All)"
  type        = string
  default     = null
}

# ===== ACR Configuration =====

variable "registry_enabled" {
  description = "Deploy Azure Container Registry"
  type        = bool
  default     = false
}

variable "acr_sku" {
  description = "ACR SKU (Basic, Standard, Premium)"
  type        = string
  default     = "Premium"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "ACR SKU must be Basic, Standard, or Premium."
  }
}

variable "acr_public_network_enabled" {
  description = "Open the ACR public endpoint to all networks. Default false: the registry is reachable only through its private endpoint, plus acr_allowed_ip_ranges when set."
  type        = bool
  default     = false
}

variable "acr_allowed_ip_ranges" {
  description = "CIDRs allowed through the ACR firewall on the public endpoint (e.g. a vendor CI that pushes images). When non-empty, the public endpoint is enabled with default_action = Deny and only these ranges allowed. Premium SKU only."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.acr_allowed_ip_ranges) == 0 || var.acr_sku == "Premium"
    error_message = "acr_allowed_ip_ranges requires acr_sku = \"Premium\" (ACR network rules are Premium-only)."
  }
}

variable "acr_private_endpoint_enabled" {
  description = "Create a private endpoint + privatelink.azurecr.io DNS zone for ACR, linked to the VNet. Premium SKU only. Set false when privatelink.azurecr.io is managed centrally and register the endpoint out-of-band."
  type        = bool
  default     = true

  validation {
    condition     = !var.registry_enabled || !var.acr_private_endpoint_enabled || var.acr_sku == "Premium"
    error_message = "acr_private_endpoint_enabled requires acr_sku = \"Premium\". Use Premium, or set acr_private_endpoint_enabled = false and allow access explicitly."
  }
}

variable "acr_zone_redundancy_enabled" {
  description = "Enable zone redundancy for ACR (Premium SKU only)"
  type        = bool
  default     = true
}

variable "enable_registry_cache" {
  description = "Enable pull-through cache from upstream registry"
  type        = bool
  default     = false
}

variable "upstream_registry_url" {
  description = "Upstream registry URL for cache (e.g., registry.company.com)"
  type        = string
  default     = null
}

variable "upstream_registry_username" {
  description = "Username for upstream registry authentication"
  type        = string
  default     = null
  sensitive   = true
}

variable "upstream_registry_password" {
  description = "Password for upstream registry authentication"
  type        = string
  default     = null
  sensitive   = true
}

variable "enable_defender_for_containers" {
  description = "Enable Microsoft Defender for Container registry scanning"
  type        = bool
  default     = true
}

# ===== Application Gateway Configuration =====

variable "appgw_sku" {
  description = "Application Gateway SKU (Standard_v2 or WAF_v2)"
  type        = string
  default     = "Standard_v2"
  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.appgw_sku)
    error_message = "Application Gateway SKU must be Standard_v2 or WAF_v2."
  }
}

variable "appgw_capacity_min" {
  description = "Minimum capacity units for Application Gateway autoscaling"
  type        = number
  default     = 2
}

variable "appgw_capacity_max" {
  description = "Maximum capacity units for Application Gateway autoscaling"
  type        = number
  default     = 10
}

variable "appgw_enable_http2" {
  description = "Enable HTTP/2 on Application Gateway"
  type        = bool
  default     = true
}

variable "appgw_waf_enabled" {
  description = "Enable WAF (only applicable with WAF_v2 SKU)"
  type        = bool
  default     = false
}

variable "appgw_waf_firewall_mode" {
  description = "WAF firewall mode (Detection or Prevention)"
  type        = string
  default     = "Prevention"
  validation {
    condition     = contains(["Detection", "Prevention"], var.appgw_waf_firewall_mode)
    error_message = "WAF firewall mode must be Detection or Prevention."
  }
}

variable "appgw_ssl_policy" {
  description = "App Gateway TLS policy. Default null: the Azure default policy. Use policy_type = \"Predefined\" with a policy_name (e.g. AppGwSslPolicy20220101S, TLS 1.2 minimum), or \"CustomV2\" with min_protocol_version TLSv1_2 (plus cipher_suites) or TLSv1_3 (no cipher_suites: TLS 1.3 suites are fixed)."
  type = object({
    policy_type          = string
    policy_name          = optional(string)
    min_protocol_version = optional(string)
    cipher_suites        = optional(list(string))
  })
  default = null

  validation {
    condition     = var.appgw_ssl_policy == null || contains(["Predefined", "CustomV2"], try(var.appgw_ssl_policy.policy_type, ""))
    error_message = "appgw_ssl_policy.policy_type must be Predefined or CustomV2."
  }

  # try(): attribute access on a null policy errors, and null is valid.
  validation {
    condition = try(
      var.appgw_ssl_policy.policy_type == "Predefined"
      ? var.appgw_ssl_policy.policy_name != null && var.appgw_ssl_policy.min_protocol_version == null && var.appgw_ssl_policy.cipher_suites == null
      : var.appgw_ssl_policy.policy_name == null && var.appgw_ssl_policy.min_protocol_version != null,
      true
    )
    error_message = "appgw_ssl_policy: Predefined needs policy_name only; CustomV2 needs min_protocol_version (optionally cipher_suites) and no policy_name."
  }

  # Azure fixes the TLS 1.3 cipher suites and rejects cipher_suites at apply time.
  validation {
    condition = try(
      var.appgw_ssl_policy.policy_type != "CustomV2" || (
        contains(["TLSv1_2", "TLSv1_3"], var.appgw_ssl_policy.min_protocol_version) &&
        !(var.appgw_ssl_policy.min_protocol_version == "TLSv1_3" && var.appgw_ssl_policy.cipher_suites != null)
      ),
      true
    )
    error_message = "appgw_ssl_policy: CustomV2 min_protocol_version must be TLSv1_2 or TLSv1_3, and cipher_suites must be omitted with TLSv1_3."
  }
}

variable "appgw_frontend_type" {
  description = <<-EOT
    App Gateway frontend exposure:
      - "private" (default): private IP frontend only, no public IP. Ingress is
        reachable only from within the VNet/peered networks (hub-and-spoke).
        Requires the Microsoft.Network/EnableApplicationGatewayNetworkIsolation
        feature registered on the subscription, and ingresses annotated
        appgw.ingress.kubernetes.io/use-private-ip: "true".
      - "public": public IP frontend only.
      - "both": public and private frontends.
    For "private"/"both", the private IP comes from appgw_private_ip_address; when
    create_vnet = true it is auto-derived from appgw_subnet_address_prefix if unset.

    NOTE: changing this on an EXISTING gateway is not an in-place operation —
    AGIC owns the listeners (lifecycle ignore_changes on http_listener), so a
    sticky listener can still reference the removed frontend and fail the apply.
    Recreate the gateway (terraform apply -replace=...azurerm_application_gateway.main)
    when switching frontend type.
  EOT
  type        = string
  default     = "private"
  validation {
    condition     = contains(["public", "private", "both"], var.appgw_frontend_type)
    error_message = "appgw_frontend_type must be one of: public, private, both."
  }
}

variable "appgw_private_ip_address" {
  description = "Static private IP for the App Gateway private frontend. Required for \"private\"/\"both\" when create_vnet = false (BYO subnet); when create_vnet = true it defaults to host .10 of appgw_subnet_address_prefix. Must be a free address inside the App Gateway subnet."
  type        = string
  default     = null

  validation {
    condition     = var.appgw_private_ip_address == null || can(cidrhost("${var.appgw_private_ip_address}/32", 0))
    error_message = "appgw_private_ip_address must be a valid IPv4 address."
  }

  validation {
    # Cross-variable (Terraform >= 1.9): a private/both frontend needs an IP —
    # either explicit, or auto-derived from the module-created subnet.
    condition     = !contains(["private", "both"], var.appgw_frontend_type) || var.create_vnet || var.appgw_private_ip_address != null
    error_message = "appgw_private_ip_address is required when appgw_frontend_type is \"private\"/\"both\" and create_vnet = false (BYO subnet)."
  }
}

# ===== PostgreSQL Configuration =====

variable "postgresql_enabled" {
  description = "Deploy PostgreSQL Flexible Server"
  type        = bool
  default     = true
}

variable "postgresql_network_mode" {
  description = "How PostgreSQL is reached privately. \"vnet_integration\" (default): servers sit in a delegated subnet. \"private_endpoint\": no delegated subnet; each server gets a private endpoint in the private endpoint subnet and uses privatelink.postgres.database.azure.com. Fixed at creation: changing it recreates every server and loses its data."
  type        = string
  default     = "vnet_integration"

  validation {
    condition     = contains(["vnet_integration", "private_endpoint"], var.postgresql_network_mode)
    error_message = "postgresql_network_mode must be vnet_integration or private_endpoint."
  }
}

variable "postgresql_sku_name" {
  description = "PostgreSQL SKU (e.g., GP_Standard_D2s_v3, MO_Standard_E4s_v3)"
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "postgresql_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "17"
  validation {
    condition     = contains(["13", "14", "15", "16", "17"], var.postgresql_version)
    error_message = "PostgreSQL version must be 13, 14, 15, 16, or 17."
  }
}

variable "postgresql_storage_mb" {
  description = "PostgreSQL storage size in MB"
  type        = number
  default     = 131072 # 128GB
}

variable "postgresql_ha_enabled" {
  description = "Enable zone-redundant high availability for PostgreSQL"
  type        = bool
  default     = false
}

variable "postgresql_backup_retention_days" {
  description = "PostgreSQL backup retention in days"
  type        = number
  default     = 7
  validation {
    condition     = var.postgresql_backup_retention_days >= 7 && var.postgresql_backup_retention_days <= 35
    error_message = "Backup retention must be between 7 and 35 days."
  }
}

variable "postgresql_admin_username" {
  description = "PostgreSQL administrator username"
  type        = string
  default     = "psqladmin"
  sensitive   = true
}

variable "postgresql_extensions" {
  description = "PostgreSQL extensions to allow-list on Azure Flexible Server"
  type        = list(string)
  default     = ["VECTOR", "PG_TRGM", "UUID-OSSP", "PGCRYPTO"]
}

variable "databases" {
  description = <<-EOT
    Map of named PostgreSQL Flexible Server instances to provision when
    postgresql_enabled = true. Each map key becomes part of the server name
    (the special key "core" preserves the legacy unsuffixed server name for
    backward compatibility). Per-entry fields fall back to the top-level
    var.postgresql_* defaults when omitted.
  EOT
  type = map(object({
    sku_name                     = optional(string)
    storage_mb                   = optional(number)
    ha_enabled                   = optional(bool)
    zone                         = optional(string)
    standby_availability_zone    = optional(string)
    backup_retention_days        = optional(number)
    geo_redundant_backup_enabled = optional(bool)
    admin_username               = optional(string)
    db_name                      = optional(string)
    extensions                   = optional(list(string))
  }))
  # Default ships only `core` so existing deployments do not see a surprise
  # second Flexible Server on upgrade. Add `temporal = {}` (or any other key)
  # in your tfvars when you actually need it — see example.tfvars.
  default = {
    core = {}
  }

  validation {
    condition     = contains(keys(var.databases), "core")
    error_message = "databases MUST contain a key named 'core'. The 'core' key maps to the existing primary Flexible Server state address (azurerm_postgresql_flexible_server.main[\"core\"]); removing it would cause Terraform to destroy and recreate the production database, which loses all data and rotates the admin password. Keep 'core' in the map even if you only need additional named instances. See azure/README.md 'Upgrading from single-DB' for the migration walkthrough."
  }
}

# ===== Storage Configuration =====

variable "storage_logging_enabled" {
  description = "Deploy logging storage account"
  type        = bool
  default     = true
}

variable "storage_logging_lifecycle" {
  description = "Lifecycle policy for logging storage"
  type = object({
    transition_to_cool_days    = number
    transition_to_archive_days = number
    expiration_days            = number
  })
  default = {
    transition_to_cool_days    = 30
    transition_to_archive_days = 90
    expiration_days            = 365
  }
}

variable "storage_general_enabled" {
  description = "Deploy general storage account"
  type        = bool
  default     = true
}

variable "storage_general_versioning" {
  description = "Enable blob versioning on the general storage account. Defaults to true so the primary consumer benefits from soft-deletion / accidental-overwrite recovery."
  type        = bool
  default     = true
}

variable "storage_general_cors_origins" {
  description = "Browser origins allowed to call the general storage account directly (presigned uploads). Empty disables CORS, which blocks every browser upload."
  type        = list(string)
  default     = []
}

variable "storage_general_lifecycle_enabled" {
  description = "Enable lifecycle management for general storage"
  type        = bool
  default     = false
}

variable "storage_general_private_endpoint_enabled" {
  description = <<-EOT
    Provision a private endpoint + privatelink.blob.core.windows.net DNS
    zone for the general storage blob endpoint, linked to the AKS VNet.
    In-cluster traffic resolves the storage hostname to the PE's private
    IP and stays on the Azure backbone. Default true.

    Set false when `create_vnet = false` and your environment manages
    privatelink.blob.core.windows.net centrally — Azure rejects multiple
    VNet links to zones of the same name, and the PE's DNS record has to
    be added to the central zone out-of-band.
  EOT
  type        = bool
  default     = true
}

variable "storage_logging_private_endpoint_enabled" {
  description = "Provision a private endpoint for the logging storage blob endpoint, registered in the same privatelink.blob.core.windows.net zone as the general storage endpoint. Default true. Same central-DNS caveat as storage_general_private_endpoint_enabled."
  type        = bool
  default     = true
}

variable "storage_public_network_access_enabled" {
  description = "Allow public network access to the logging and general storage accounts. Default false: they are reachable only through their private endpoints, so every enabled account needs its private endpoint, and browser uploads via presigned URLs need a private network path (and privatelink DNS) to the endpoint. Set true for a public App Gateway frontend."
  type        = bool
  default     = false

  validation {
    condition = var.storage_public_network_access_enabled || (
      (!var.storage_logging_enabled || var.storage_logging_private_endpoint_enabled) &&
      (!var.storage_general_enabled || var.storage_general_private_endpoint_enabled)
    )
    error_message = "storage_public_network_access_enabled = false requires storage_logging_private_endpoint_enabled and storage_general_private_endpoint_enabled for each enabled storage account."
  }

  # Browsers upload straight to general storage via presigned URLs. With a
  # public App Gateway those browsers are on the internet, so a private-only
  # account silently breaks uploads — make the choice explicit.
  validation {
    condition     = var.storage_public_network_access_enabled || !var.storage_general_enabled || !contains(["public", "both"], var.appgw_frontend_type)
    error_message = "appgw_frontend_type = \"public\"/\"both\" serves internet users, whose browsers upload to general storage via presigned URLs. Set storage_public_network_access_enabled = true, or use a private frontend."
  }
}

variable "storage_replication_type" {
  description = "Replication for the logging and general storage accounts: LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS. Default LRS. Moving to or from a zone-redundant type (ZRS, GZRS, RAGZRS) recreates the account, so choose it before the first apply. Azure has no archive tier for zone-redundant types, so with ZRS, GZRS or RAGZRS the logging lifecycle skips transition_to_archive_days."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.storage_replication_type)
    error_message = "storage_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "storage_delete_retention_days" {
  description = "Soft-delete retention in days for blobs and containers in the logging and general storage accounts. Default 7."
  type        = number
  default     = 7

  validation {
    condition     = var.storage_delete_retention_days >= 1 && var.storage_delete_retention_days <= 365
    error_message = "storage_delete_retention_days must be between 1 and 365."
  }
}

variable "storage_logging_account_name" {
  description = "Override storage account name for logging storage (default: {project}{environment}logging). Used to dodge Azure's ~14-day global name reservation when redeploying. Must be 3-24 lowercase alphanumeric chars."
  type        = string
  default     = null
  validation {
    condition     = var.storage_logging_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_logging_account_name))
    error_message = "storage_logging_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "storage_general_account_name" {
  description = "Override storage account name for general storage (default: {project}{environment}storage). Used to dodge Azure's ~14-day global name reservation when redeploying. Must be 3-24 lowercase alphanumeric chars."
  type        = string
  default     = null
  validation {
    condition     = var.storage_general_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_general_account_name))
    error_message = "storage_general_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

# ===== Workload Identity =====
#
# Generic AKS Workload Identity map. One UAMI per key, federated to
# <service_account> across every namespace in <namespaces>, with one Azure RBAC
# role assignment per role_assignments entry.
#
# The default ships the three platform identities (logging, documents,
# documents-processing). Their namespaces / service accounts / roles are visible
# and overridable HERE; the dynamic bits each role needs — the target resource
# ID, the Foundry role-definition ID, and logging's cluster-derived UAMI name —
# are resolved in azure/workload-identity.tf, because a variable default cannot
# reference resources or other variables.
#
# Each role_assignments entry targets a resource one of two ways:
#   - scope_ref : a symbolic target the module resolves to a live resource ID.
#                 One of: "logging_storage", "general_storage", "foundry". A role
#                 whose scope_ref's feature flag is off is dropped; an identity
#                 left with no roles is dropped too.
#   - scope     : a raw ARM resource ID (typical for operator-defined workloads).
# Set EXACTLY ONE of scope_ref / scope, and EXACTLY ONE of role_definition_name /
# role_definition_id. The sentinel role_definition_name = "__foundry_user__"
# expands (in code) to the Foundry User role by ID — its display name is unstable
# during the "Azure AI User" -> "Foundry User" rename.
#
# `requires` (optional, a scope_ref enum value) gates the whole identity on a
# feature flag: the identity is NOT created unless that target is enabled. Use it
# when an identity must track a flag independently of its roles — e.g.
# documents-processing requires general_storage so it is not created on a
# storage-off cluster even when it still holds the (flag-independent) foundry
# role. scope_ref targets remain orthogonal: `foundry` is gated only on
# foundry_enabled and is freely usable by any workload, storage-bound or not.
#
# NOTE: setting this variable REPLACES the default map (standard Terraform
# semantics). To add a workload, copy the three defaults and append yours.
variable "workload_identities" {
  description = "AKS Workload Identity map: one UAMI per key, federated to a ServiceAccount across namespaces, with Azure RBAC role assignments. scope_ref values are resolved to live resource IDs in azure/workload-identity.tf."
  type = map(object({
    namespaces      = list(string)
    service_account = string
    name            = optional(string) # UAMI name override; default id-<prefix>-<key>-identity (logging is special-cased in code)
    requires        = optional(string) # gate: only create this identity when the named target's feature flag is on (scope_ref enum value)
    role_assignments = optional(list(object({
      scope                = optional(string) # raw ARM resource ID
      scope_ref            = optional(string) # symbolic: logging_storage | general_storage | foundry
      role_definition_name = optional(string) # or the "__foundry_user__" sentinel
      role_definition_id   = optional(string)
    })), [])
  }))

  default = {
    logging = {
      namespaces      = ["monitoring"]
      service_account = "loki"
      requires        = "logging_storage"
      role_assignments = [{
        scope_ref            = "logging_storage"
        role_definition_name = "Storage Blob Data Contributor"
      }]
    }
    documents = {
      namespaces      = ["core"]
      service_account = "documents"
      requires        = "general_storage"
      role_assignments = [{
        scope_ref            = "general_storage"
        role_definition_name = "Storage Blob Data Contributor"
      }]
    }
    "documents-processing" = {
      namespaces      = ["core"]
      service_account = "documents-processing"
      requires        = "general_storage" # storage-bound worker: do NOT create when general storage is off, even if foundry is on
      role_assignments = [
        {
          scope_ref            = "general_storage"
          role_definition_name = "Storage Blob Data Contributor"
        },
        {
          scope_ref            = "foundry"
          role_definition_name = "__foundry_user__"
        },
      ]
    }
    intent = {
      namespaces      = ["core"]
      service_account = "intent"
      requires        = "foundry"
      role_assignments = [{
        scope_ref            = "foundry"
        role_definition_name = "__foundry_user__"
      }]
    }
  }

  validation {
    condition     = alltrue([for wi in values(var.workload_identities) : length(wi.namespaces) > 0])
    error_message = "Each workload_identities entry must list at least one namespace (one federated credential is created per namespace)."
  }

  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) : alltrue([
        for ra in coalesce(wi.role_assignments, []) :
        (ra.scope != null) != (ra.scope_ref != null)
      ])
    ])
    error_message = "Each role_assignments entry must set exactly one of scope or scope_ref."
  }

  # KEEP IN SYNC: the valid scope_ref / requires target set is declared in four
  # places — this enum, the `requires` enum below, and local.wi_scope_refs +
  # local.wi_scope_available in azure/workload-identity.tf. Add a target to all
  # of them together.
  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) : alltrue([
        for ra in coalesce(wi.role_assignments, []) :
        ra.scope_ref == null || contains(["logging_storage", "general_storage", "foundry"], ra.scope_ref)
      ])
    ])
    error_message = "role_assignments[].scope_ref must be one of: logging_storage, general_storage, foundry."
  }

  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) :
      wi.requires == null || contains(["logging_storage", "general_storage", "foundry"], wi.requires)
    ])
    error_message = "workload_identities[].requires must be null or one of: logging_storage, general_storage, foundry."
  }

  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) : alltrue([
        for ra in coalesce(wi.role_assignments, []) :
        (ra.role_definition_name != null) != (ra.role_definition_id != null)
      ])
    ])
    error_message = "Each role_assignments entry must set exactly one of role_definition_name or role_definition_id."
  }

  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) : alltrue([
        for ns in wi.namespaces : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", ns))
      ])
    ])
    error_message = "Each namespace must follow Kubernetes naming rules: lowercase alphanumeric with hyphens, starting/ending with alphanumeric (e.g. \"core\", \"tenant-a\")."
  }

  validation {
    condition = alltrue([
      for wi in values(var.workload_identities) :
      length(distinct(wi.namespaces)) == length(wi.namespaces)
    ])
    error_message = "workload_identities[].namespaces must not contain duplicates — duplicate namespaces produce identical federated-credential for_each keys and fail at plan."
  }
}

# ===== Teleport Access Configuration =====

variable "access_mode" {
  description = "K8s API access mode (teleport or vpn)"
  type        = string
  default     = "teleport"
  validation {
    condition     = contains(["teleport", "vpn"], var.access_mode)
    error_message = "access_mode must be 'teleport' or 'vpn'"
  }
}

variable "vpn_gateway_ips" {
  description = "VPN gateway IPs (legacy, for vpn mode)"
  type        = list(string)
  default     = []
}

variable "teleport_proxy_address" {
  description = "Teleport proxy address as host:port (required when access_mode = teleport). Defaults to empty — supply your own Teleport proxy."
  type        = string
  default     = ""
}

variable "teleport_join_token" {
  description = "Teleport agent join token (used for all services: kube, app, db, discovery)"
  type        = string
  default     = null
  sensitive   = true
}

variable "teleport_ca_pin" {
  description = "Teleport CA pin (optional, recommended for prod)"
  type        = string
  default     = null
  sensitive   = true
}

variable "teleport_version" {
  description = "Teleport version"
  type        = string
  default     = "18.5.1"
}

variable "teleport_agent_chart_repository" {
  description = "Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access_mode = teleport — supply your own."
  type        = string
  default     = ""
}

variable "teleport_agent_image" {
  description = "Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters)."
  type        = string
  default     = ""
}

variable "teleport_gateway_ip" {
  description = "Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP."
  type        = string
  default     = null
}

variable "teleport_db_enabled" {
  description = "Enable Teleport database service for PostgreSQL"
  type        = bool
  default     = true
}

# ===== Terraform Cloud Agent Configuration =====

variable "tfc_agent_enabled" {
  description = "Deploy Terraform Cloud Agent for private cluster access"
  type        = bool
  default     = false
}

variable "tfc_agent_token" {
  description = "Terraform Cloud Agent token (sensitive, set via TF_VAR_tfc_agent_token)"
  type        = string
  default     = null
  sensitive   = true
}

variable "tfc_agent_version" {
  description = "TFC Agent container image tag"
  type        = string
  default     = "1.28.5"
}

# ===== Private Cluster Configuration =====

variable "private_cluster_enabled" {
  description = "Private cluster API (no public endpoint). Default true. Terraform must run from a host that can reach and resolve the private API: a runner inside the VNet or a peered network (e.g. an HCP Terraform agent on a VM). The in-cluster TFC agent cannot bootstrap a private cluster. Set false (with api_server_authorized_cidrs) to opt into a public API. Changing this forces a new cluster."
  type        = bool
  default     = true
}

variable "aks_private_dns_zone_id" {
  description = "Private DNS zone for the private AKS API. null (default): AKS creates and manages a zone (\"System\"). \"None\": no private zone; the API name resolves through public DNS to the private IP. A zone ID: a customer-owned privatelink.<region>.azmk8s.io zone, which requires aks_identity_id with Private DNS Zone Contributor on the zone. Changing it forces a new cluster."
  type        = string
  default     = null

  validation {
    condition     = var.aks_private_dns_zone_id == null || contains(["System", "None"], coalesce(var.aks_private_dns_zone_id, "x")) || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/[^/]+$", coalesce(var.aks_private_dns_zone_id, "x")))
    error_message = "aks_private_dns_zone_id must be null, \"System\", \"None\", or a full ARM private DNS zone ID."
  }
  validation {
    condition     = var.aks_private_dns_zone_id == null || var.private_cluster_enabled
    error_message = "aks_private_dns_zone_id applies only to a private cluster (private_cluster_enabled = true)."
  }
  validation {
    condition     = var.aks_private_dns_zone_id == null || contains(["System", "None"], coalesce(var.aks_private_dns_zone_id, "x")) || var.aks_identity_id != null
    error_message = "A customer-owned aks_private_dns_zone_id requires aks_identity_id: a user-assigned identity with Private DNS Zone Contributor on the zone."
  }
}

variable "aks_identity_id" {
  description = "ARM resource ID of a user-assigned identity for the AKS control plane. Default null: system-assigned. Required with a customer-owned aks_private_dns_zone_id. Grant it Private DNS Zone Contributor on that zone, and Network Contributor on the VNet (AKS creates the zone's VNet link; with a System or None zone the AKS subnet is enough) and on its route table, before the first apply. With create_vnet = true the module grants the network role. The Terraform identity needs Managed Identity Operator on it. In another subscription than the provider, also set aks_identity_principal_id. Changing it on an existing cluster updates the control-plane identity in place."
  type        = string
  default     = null

  validation {
    condition     = var.aks_identity_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", coalesce(var.aks_identity_id, "x")))
    error_message = "aks_identity_id must be a full ARM user-assigned identity ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/...)."
  }
}

variable "aks_identity_principal_id" {
  description = "Principal (object) ID of the aks_identity_id identity. Default null: the module looks it up, which only works when the identity is in the provider's subscription. Set it for an identity in another subscription, such as a hub."
  type        = string
  default     = null

  validation {
    condition     = var.aks_identity_principal_id == null || var.aks_identity_id != null
    error_message = "aks_identity_principal_id requires aks_identity_id."
  }
}

# ===== Azure AI Foundry =====

variable "foundry_enabled" {
  description = "Provision the Azure AI Foundry module (account, private endpoint, and intent workload identity)"
  type        = bool
  default     = false
}

variable "foundry_sku_name" {
  description = "SKU for the Azure AI Foundry (AI Services) account"
  type        = string
  default     = "S0"
}

variable "foundry_project_management_enabled" {
  description = "Whether the Foundry account has AI Foundry project management enabled. ForceNew — changing it recreates the account (soft-delete purge risk; cascades to the private endpoint and all foundry-scoped role assignments). Default false; set true only for environments whose account was created with it enabled so their plan does not force a replace."
  type        = bool
  default     = false
}

variable "foundry_local_auth_enabled" {
  description = "Whether the Foundry account accepts key-based (API-key) data-plane auth in addition to Entra ID (AAD). Default false — AAD-only, the intent workload identity is the sole caller. Set true when a consumer needs the account keys. Updates in place (not ForceNew); network restrictions (private endpoint, network_acls Deny, public access off) are unaffected."
  type        = bool
  default     = false
}

variable "foundry_location" {
  description = "Region for the Foundry account. Defaults to the resource group location. Override when Claude (or another model family) is not available in the stack's primary region — Foundry MaaS catalogs are region-gated during preview."
  type        = string
  default     = null
}

variable "foundry_private_dns_managed_externally" {
  description = "When true, Terraform does NOT create or link the privatelink.services.ai.azure.com private DNS zone. Use when create_vnet=false and your environment manages this privatelink zone centrally — Azure rejects a second VNet link to a zone of the same name. The Foundry private endpoint then registers into foundry_existing_private_dns_zone_id (if set) or omits its DNS zone group entirely (central policy/DINE handles registration)."
  type        = bool
  default     = false
}

variable "foundry_existing_private_dns_zone_id" {
  description = "ARM resource ID of a centrally-managed privatelink.services.ai.azure.com DNS zone the Foundry private endpoint should register into. Only used when foundry_private_dns_managed_externally=true. Leave null to let central policy/DINE handle A-record registration."
  type        = string
  default     = null
}
