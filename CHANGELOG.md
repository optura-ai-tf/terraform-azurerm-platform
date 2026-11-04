# Changelog

All notable changes to the Azure AKS platform module are documented here. This
module is versioned independently of the rest of the repository; tags are of the
form `azure/platform/vX.Y.Z`.

## Unreleased

## 1.1.0 — 2026-11-04

Release as **1.1.0** (Version Bump workflow, `minor`). Every new input is
optional and defaults to the 1.0.0 behaviour, so existing workspaces plan no
changes, with two exceptions: the upgrade channel under Changed and the
Foundry note under Fixed.

### Added

- `existing_private_endpoint_subnet_id`: a dedicated subnet for the ACR,
  Foundry, Key Vault, and storage private endpoints. Default: the AKS subnet.
- `log_analytics_workspace_id`: Container Insights on the AKS cluster. The
  module creates the data collection rule and its association. Set
  `log_analytics_workspace_location` when the workspace is in another region.
- `azure_policy_enabled`: the Azure Policy add-on (Gatekeeper).
- `appgw_ssl_policy`: App Gateway TLS policy (predefined or `CustomV2`).
- `storage_replication_type`, `storage_delete_retention_days`,
  `key_vault_soft_delete_retention_days`: replication and soft-delete retention,
  previously fixed at `LRS` and 7 days.
- Outputs `database_server_ids` and `foundry_account_id`, so callers can attach
  diagnostic settings to every resource.
- `private_dns_zones_managed_externally` and `existing_private_dns_zone_ids`:
  use central (hub) private DNS zones for blob, Key Vault, ACR, Foundry, and
  PostgreSQL. A null zone ID skips the zone group so central policy registers
  the record. The Foundry-only inputs still work.
- `postgresql_network_mode = "private_endpoint"`: PostgreSQL over a private
  endpoint with `privatelink.postgres.database.azure.com`, no delegated subnet.
  Default `vnet_integration`.
- `aks_private_dns_zone_id` and `aks_identity_id`: a customer-owned private
  API zone (or `"None"`), with a user-assigned control-plane identity.
  `aks_identity_principal_id` covers an identity in another subscription.

### Changed

- `aks_automatic_upgrade_channel` (default `"patch"`): AKS now applies patch
  releases automatically, weekly on Sunday 02:00–06:00 UTC. Existing clusters
  plan an in-place update. Set it to `null` to keep upgrades manual.
- `kubernetes_version` must be a minor version (for example `1.35`) while the
  channel is set. If you pin a patch version (for example `1.34.7`), drop the
  patch component or set `aks_automatic_upgrade_channel = null` before you
  upgrade, or the plan fails.

### Fixed

- A private endpoint whose DNS zone is external with no zone ID no longer
  loses the zone group that central (deploy-if-not-exists) policy adds: the
  next plan removed it and broke name resolution. These endpoints are now
  separate `*_policy_dns` resources with `ignore_changes` on the zone group.
  A Foundry workspace with `foundry_private_dns_managed_externally = true` and
  no zone ID recreates its private endpoint once (new IP). To avoid this, add
  a `moved` block in the root module before you upgrade:

  ```hcl
  moved {
    from = module.<name>.azurerm_private_endpoint.foundry[0]
    to   = module.<name>.azurerm_private_endpoint.foundry_policy_dns[0]
  }
  ```

  A matching `moved` block between `<resource>` and `<resource>_policy_dns`
  (same index or key) also avoids the recreation when you later switch a DNS
  zone entry between a zone ID and `null`.
- The `availability_zones` description no longer claims East US 2 has only
  zones 1 and 3. Zone restrictions are per VM size and subscription.

## 1.0.0 — 2026-10-30

### Breaking changes

Release as **1.0.0** (Version Bump workflow, `major`). A 0.x workspace that
upgrades without changes plans to destroy and recreate its AKS cluster, because
`private_cluster_enabled` and `pod_cidr` both force a new cluster. See
[Upgrading to 1.0.0](README.md#upgrading-to-100) for the settings that keep 0.x
behaviour.

- **Private by default**. Nothing the module creates is open to the
  internet unless the caller opts in:
  - AKS API: `private_cluster_enabled` defaults to `true`. Set `false` with
    `api_server_authorized_cidrs` for a public, CIDR-restricted API.
  - Storage (logging and general): private endpoints on,
    `storage_public_network_access_enabled = false`. A public App Gateway
    frontend must set storage public, or browser presigned uploads break; plan
    time validation enforces this.
  - Key Vault (CMK): firewall `Deny` with the `AzureServices` bypass, plus a
    private endpoint and `privatelink.vaultcore.azure.net`. Terraform must reach
    the vault through the endpoint or `key_vault_allowed_ip_ranges`.
  - ACR: public access off, private endpoint and `privatelink.azurecr.io`.
    `acr_allowed_ip_ranges` allow-lists a vendor CI that pushes (Premium only).
- **Azure CNI Overlay with Cilium by default**. New `pod_cidr`, default
  `100.64.0.0/16`: pods get IPs from a range that is never routed, so the VNet
  only holds nodes and endpoints. Overlay runs the Cilium dataplane and network
  policy. `pod_cidr = null` keeps the 0.x networking (no overlay, Azure
  dataplane).
- **`node_groups` replaces `system_node_pool` and `user_node_pools`**, in the
  same shape as the AWS module. The system pool is the `system` key;
  every other key is a user pool. Field renames: `min_count` → `min_size`,
  `max_count` → `max_size`, `os_disk_size_gb` → `disk_size`, and a fixed
  `node_count = N` becomes `min_size = N, max_size = N`. Every entry needs a
  `workload-type` label, including `system`. State addresses are unchanged, so
  nothing is recreated. A pool whose `min_size` equals `max_size` now runs at a
  fixed size instead of autoscaling, which updates in place.

### Added

- `aks_outbound_type`. `loadBalancer` (default) keeps the outbound-only
  public IP. `userDefinedRouting` sends egress through the AKS subnet's route
  table, e.g. to a hub firewall, and requires `create_vnet = false`.
- `network_data_plane`. `null` follows `pod_cidr`; `"azure"` keeps
  overlay without Cilium.
- Validations for `pod_cidr` (valid CIDR, no overlap with `service_cidr`, the
  module-created VNet, or a BYO VNet) and for the App Gateway subnet size
  (/24 or smaller with overlay).
- A module-created App Gateway subnet gets the
  `Microsoft.Network/applicationGateways` delegation when overlay is on or the
  frontend is private. BYO subnets must add it themselves.

### Changed

- **Default `kubernetes_version` is now `1.35`** (was `1.34`). A cluster that
  relies on the default upgrades in place on its next apply. Pin
  `kubernetes_version = "1.34"` to stay.
- `private_cluster_enabled` no longer requires `tfc_agent_enabled`. The
  in-cluster TFC agent can't bootstrap a private cluster; run Terraform from a
  host in the VNet instead.
- The CMK keys wait on `time_sleep.key_vault_ready` (admin role, private
  endpoint and DNS link) before creation. Existing keys are not replaced.
