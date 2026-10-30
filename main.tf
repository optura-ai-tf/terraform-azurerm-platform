# Terraform configuration.
# Provider constraints use minimum-version floors so a consuming root can pin
# its own upper bounds (and share one lock file across several modules) without
# fighting a narrow range declared here. Exception: azurerm is capped < 5.0
# until the module is migrated to the v5 schema (see the azurerm block below).
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Cap below azurerm 5.0 — v5 reworked the private-DNS vnet link (breaking).
      # Lift after migrating the module to the v5 schema.
      version = ">= 4.65, < 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.6"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# Azure Provider
provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    # Storage accounts are private by default and their private endpoints
    # come after them, so skip data-plane calls during create. This module
    # has no data-plane storage resources: containers and management
    # policies go through ARM (storage_account_id).
    storage {
      data_plane_available = false
    }
  }
}

# Azure AD Provider
provider "azuread" {}

# Auto-detect if running inside Kubernetes cluster (TFC agent pod)
# When true, use in-cluster service account auth; otherwise use external AKS auth
locals {
  is_in_cluster = fileexists("/var/run/secrets/kubernetes.io/serviceaccount/token")
}

# Kubernetes/Helm authentication locals
locals {
  k8s_host    = local.is_in_cluster ? "https://kubernetes.default.svc" : azurerm_kubernetes_cluster.main.kube_admin_config[0].host
  k8s_ca_cert = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") : base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate)
  k8s_token   = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/token") : null
  # Client cert auth only used when NOT in-cluster
  k8s_client_cert = local.is_in_cluster ? null : base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate)
  k8s_client_key  = local.is_in_cluster ? null : base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key)
}

# Kubernetes Provider
# Uses in-cluster auth when running from TFC agent, external auth otherwise
provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca_cert
  token                  = local.k8s_token
  client_certificate     = local.k8s_client_cert
  client_key             = local.k8s_client_key
}

provider "kubectl" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca_cert
  token                  = local.k8s_token
  client_certificate     = local.k8s_client_cert
  client_key             = local.k8s_client_key
  load_config_file       = false
}

# Helm Provider
# Uses in-cluster auth when running from TFC agent, external auth otherwise
provider "helm" {
  kubernetes = {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca_cert
    token                  = local.k8s_token
    client_certificate     = local.k8s_client_cert
    client_key             = local.k8s_client_key
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Naming convention locals
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  resource_names = {
    resource_group = "rg-${local.name_prefix}"
    vnet           = "vnet-${local.name_prefix}"
    aks            = "aks-${local.name_prefix}"
    acr            = "${var.project_name}${var.environment}acr"
    appgw          = "appgw-${local.name_prefix}"
    appgw_pip      = "pip-appgw-${local.name_prefix}"
    postgresql     = "psql-${local.name_prefix}"
    key_vault      = "kv-${local.name_prefix}"
  }

  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
    }
  )
}

# Main resource group
resource "azurerm_resource_group" "main" {
  name     = local.resource_names.resource_group
  location = var.region

  tags = local.common_tags
}
