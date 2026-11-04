# User-assigned managed identity for Application Gateway
# Used by AGIC for managing Application Gateway configuration
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "id-${local.resource_names.appgw}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

locals {
  appgw_public_enabled  = contains(["public", "both"], var.appgw_frontend_type)
  appgw_private_enabled = contains(["private", "both"], var.appgw_frontend_type)

  # Effective static private frontend IP: explicit value wins; otherwise, when
  # the module owns the subnet (create_vnet = true), derive host .10 of the
  # App Gateway subnet prefix. BYO-subnet callers must set it explicitly
  # (enforced by the appgw_private_ip_address validation).
  appgw_private_ip = (
    var.appgw_private_ip_address != null ? var.appgw_private_ip_address :
    var.create_vnet ? cidrhost(var.appgw_subnet_address_prefix, 10) : null
  )

  # Frontend IP configurations, built per appgw_frontend_type. The public
  # frontend keeps its original name ("appgw-frontend-ip") so existing public
  # deployments aren't replaced.
  appgw_frontends = concat(
    local.appgw_public_enabled ? [{
      name                 = "appgw-frontend-ip"
      public_ip_address_id = one(azurerm_public_ip.appgw[*].id)
      subnet_id            = null
      private_ip_address   = null
    }] : [],
    local.appgw_private_enabled ? [{
      name                 = "appgw-frontend-ip-private"
      public_ip_address_id = null
      subnet_id            = local.appgw_subnet_id
      private_ip_address   = local.appgw_private_ip
    }] : []
  )

  # The bootstrap listener binds to the public frontend when present, else the
  # private one. AGIC manages the real listeners at runtime.
  appgw_primary_frontend_name = local.appgw_public_enabled ? "appgw-frontend-ip" : "appgw-frontend-ip-private"
}

# State migration: the public IP gained `count`, moving its address from
# azurerm_public_ip.appgw to azurerm_public_ip.appgw[0]. The moved block keeps
# existing public deployments in place (no destroy/recreate of the IP) when they
# set appgw_frontend_type = "public"; when the frontend is private (count = 0)
# Terraform removes it, which is the intended behaviour.
moved {
  from = azurerm_public_ip.appgw
  to   = azurerm_public_ip.appgw[0]
}

# Public IP for Application Gateway (only when the frontend exposes a public IP)
resource "azurerm_public_ip" "appgw" {
  count               = local.appgw_public_enabled ? 1 : 0
  name                = local.resource_names.appgw_pip
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones

  tags = local.common_tags

  lifecycle {
    # Ignore zones changes to prevent replacement when availability zones are updated
    # The Public IP will retain its original zones, which is acceptable
    ignore_changes = [zones]
  }
}

# WAF Policy (if WAF_v2 SKU)
resource "azurerm_web_application_firewall_policy" "main" {
  count               = var.appgw_sku == "WAF_v2" ? 1 : 0
  name                = "wafpolicy-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  policy_settings {
    enabled                     = var.appgw_waf_enabled
    mode                        = var.appgw_waf_firewall_mode
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  tags = local.common_tags
}

# Application Gateway
resource "azurerm_application_gateway" "main" {
  name                = local.resource_names.appgw
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  zones               = var.availability_zones

  # SKU configuration
  sku {
    name = var.appgw_sku
    tier = var.appgw_sku
  }

  # Autoscaling configuration
  autoscale_configuration {
    min_capacity = var.appgw_capacity_min
    max_capacity = var.appgw_capacity_max
  }

  # TLS policy; Azure default when null
  dynamic "ssl_policy" {
    for_each = var.appgw_ssl_policy != null ? [var.appgw_ssl_policy] : []
    content {
      policy_type          = ssl_policy.value.policy_type
      policy_name          = ssl_policy.value.policy_name
      min_protocol_version = ssl_policy.value.min_protocol_version
      cipher_suites        = ssl_policy.value.cipher_suites
    }
  }

  # Managed identity for AGIC integration
  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.appgw.id
    ]
  }

  # Gateway IP configuration
  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = local.appgw_subnet_id
  }

  # Frontend IP configuration(s) — public, private, or both per appgw_frontend_type
  dynamic "frontend_ip_configuration" {
    for_each = local.appgw_frontends
    content {
      name                          = frontend_ip_configuration.value.name
      public_ip_address_id          = frontend_ip_configuration.value.public_ip_address_id
      subnet_id                     = frontend_ip_configuration.value.subnet_id
      private_ip_address            = frontend_ip_configuration.value.private_ip_address
      private_ip_address_allocation = frontend_ip_configuration.value.private_ip_address != null ? "Static" : null
    }
  }

  # Frontend ports
  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  # Default backend pool (AGIC will manage actual pools)
  backend_address_pool {
    name = "default-backend-pool"
  }

  # Default backend HTTP settings (AGIC will manage actual settings)
  backend_http_settings {
    name                  = "default-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  # Default HTTP listener (AGIC will manage actual listeners). Bound to the
  # primary frontend at CREATE time. Because http_listener is in ignore_changes
  # below (AGIC owns listeners at runtime), this binding is NOT updated in place
  # if appgw_frontend_type later changes — a stale listener could reference a
  # removed frontend and fail the apply. Switching frontend type on an existing
  # gateway therefore requires a recreate (terraform apply -replace=...main).
  http_listener {
    name                           = "default-listener"
    frontend_ip_configuration_name = local.appgw_primary_frontend_name
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  # Default routing rule (low priority so AGIC rules take precedence)
  request_routing_rule {
    name                       = "default-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "default-listener"
    backend_address_pool_name  = "default-backend-pool"
    backend_http_settings_name = "default-http-settings"
    priority                   = 10000
  }

  # Enable HTTP/2
  http2_enabled = var.appgw_enable_http2

  # WAF Policy (if WAF_v2)
  firewall_policy_id = var.appgw_sku == "WAF_v2" ? azurerm_web_application_firewall_policy.main[0].id : null

  tags = local.common_tags

  lifecycle {
    # AGIC and cert-manager manage these resources dynamically
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_port,
      http_listener,
      probe,
      request_routing_rule,
      url_path_map,
      redirect_configuration,
      ssl_certificate, # Managed by cert-manager via AGIC
      tags["ingress-for-aks-cluster-id"],
      tags["managed-by-k8s-ingress"]
    ]
  }
}
