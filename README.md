# Azure AKS Platform Module

Production-ready AKS cluster with VNet, ACR, Application Gateway (AGIC), optional PostgreSQL, Workload Identity, Teleport access, and Azure AI Foundry — delivered as a single reusable Terraform module.

This module is the packaged form of the platform's `azure/` root configuration. Calling it gives you the same cluster, network, registry, ingress, and data-plane topology, with every feature gated behind an input flag. The consuming root owns the backend and provider authentication; the module owns the resources and their wiring.

## Usage

The module is distributed through two channels. Pick the one that matches where you run Terraform.

### Terraform Registry

```hcl
module "platform" {
  source  = "optura-ai-tf/platform/azurerm"
  version = "~> 1.0"

  subscription_id = var.subscription_id
  environment     = "dev"
  region          = "eastus2"
  project_name    = "optura"

  access_mode            = "teleport"
  teleport_proxy_address = "teleport.example.com:443"
}
```

Pin `version` to a `~>` range so patch releases flow in but a major version bump is opt-in. Upgrading from 0.x? Read [Upgrading to 1.0.0](#upgrading-to-100) first: 1.0.0 makes every endpoint private by default.

### Git source

To pin directly to a tag without the registry:

```hcl
module "platform" {
  source = "git::https://github.com/optura-ai-tf/terraform-azurerm-platform.git?ref=v0.5.0"

  subscription_id = var.subscription_id
  environment     = "dev"
  region          = "eastus2"
  project_name    = "optura"
}
```

Always pin `?ref=` to a release tag (`vX.Y.Z`); `main` is not a stable contract.

### A complete invocation

```hcl
module "platform" {
  source  = "optura-ai-tf/platform/azurerm"
  version = "~> 1.0"

  subscription_id = var.subscription_id # supplied by the root; see below

  environment  = "dev"
  region       = "eastus2"
  project_name = "optura"

  tags = {
    CostCenter = "Engineering"
    Owner      = "Platform Team"
  }

  # Azure AD group for cluster admins (see "AKS admin group" below).
  aks_admin_group_name = "AKS Terraform Admins"

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
      max_size                    = 5
      disk_size                   = 256
      temporary_name_for_rotation = "apptmp"
      labels                      = { "workload-type" = "application" }
    }
  }

  # Managed PostgreSQL (enabled by default).
  postgresql_sku_name   = "GP_Standard_D2s_v3"
  postgresql_ha_enabled = false

  # Zero-trust kubectl and database access via a Teleport agent.
  access_mode            = "teleport"
  teleport_proxy_address = "teleport.example.com:443"
}
```

A runnable version lives in [`examples/complete/`](./examples/complete/). Throughout this document, "set the `X` input" means add `X = ...` to your `module` block (or wire it to a root variable), not edit a tfvars file inside the module.

### What the root owns

The module declares **no backend and no `cloud {}` block** — your root configuration owns state. Use whatever your platform standardizes on (an HCP `cloud {}` block, or an `azurerm` storage-account backend).

Provider **authentication** is also the root's responsibility. The module declares the `azurerm` / `azuread` providers and pins their version floors, but credentials come from the root's environment (`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, or a workspace-attached managed identity / OIDC). The Azure service principal needs **Owner** (not just Contributor) on the target subscription, because the module creates role assignments.

Create the service principal once per subscription:

```bash
# Select the intended deployment subscription explicitly and confirm it — the
# SP gets Owner on whatever $SUB_ID points at, so don't rely on the ambient
# "active" subscription.
az account set --subscription "<subscription-name-or-id>"
az account show --query '{name:name, id:id}' -o table   # confirm this is the right subscription
SUB_ID=$(az account show --query id -o tsv)

az ad sp create-for-rbac \
  --name "tfc-<project>-<env>" \
  --role "Owner" \
  --scopes "/subscriptions/$SUB_ID" \
  --years 2
```

Save the output — the `password` cannot be retrieved later — and wire it into the workspace's **environment** variables (not `terraform.tfvars`; these are auth, not config):

| Value | Workspace env var |
|---|---|
| SP output `appId`    | `ARM_CLIENT_ID` |
| SP output `password` | `ARM_CLIENT_SECRET` (sensitive) |
| SP output `tenant`   | `ARM_TENANT_ID` |
| `$SUB_ID` (from `az account show`, not an SP-creation field) | `ARM_SUBSCRIPTION_ID` |

`subscription_id` is a **required input** the root supplies — typically via `TF_VAR_subscription_id` (get it with `az account show --query id -o tsv`) so it never lands in committed HCL.

> First apply takes **~15 minutes**. After it lands, configure kubectl with
> `az aks get-credentials --resource-group rg-<project>-<env> --name aks-<project>-<env>`
> (the module also emits this as the `kubectl_config_command` output).

### AKS admin group

AKS binds cluster-admin to an Azure AD group. Create one per environment and feed its identity to the module:

```bash
az ad group create \
  --display-name "<Project> <Env> AKS Admins" \
  --mail-nickname "<project>-<env>-aks-admins"

az ad group member add \
  --group "<Project> <Env> AKS Admins" \
  --member-id $(az ad signed-in-user show --query id -o tsv)

az ad group show --group "<Project> <Env> AKS Admins" --query id -o tsv  # the Object ID
```

Then set either input on the module call:

| Module input | Source value |
|---|---|
| `aks_admin_group_name` | the group `displayName` (e.g. `"<Project> <Env> AKS Admins"`) |
| `aks_admin_group_id` | the group Object `id` |

If your service principal has `Group.Read.All`, `aks_admin_group_name` alone is enough — the module looks the group up by name. If it doesn't (common), set `aks_admin_group_id` directly and the module skips the lookup.

---

## Module notes

A few consumption rules are specific to how this module is wired.

- **No meta-arguments on the module call.** The module retains its own `provider` blocks (`azurerm`, `azuread`, `kubernetes`, `helm`) so it can self-configure in-cluster auth. Terraform forbids `count`, `for_each`, and `depends_on` on a module that declares providers. Call this module **once per workspace**, unconditionally — gate features with the input flags instead of wrapping the whole call in a `count`.
- **In-cluster auto-detection.** The module auto-detects its runtime: when it sees a Kubernetes service-account token at `/var/run/secrets/kubernetes.io/serviceaccount/token` (i.e. it is executing inside a TFC agent pod on the cluster), the `kubernetes` and `helm` providers use in-cluster service-account auth (`https://kubernetes.default.svc`). Otherwise they use the cluster's admin kubeconfig over the public/private API endpoint. This is what lets the same module bootstrap a public cluster and then run from inside it once locked down — no consumer wiring required.
- **Private by default.** Nothing the module creates is reachable from the internet unless you opt in: private AKS API, private App Gateway frontend, and storage, Key Vault, and ACR behind private endpoints. Terraform must therefore run from a host that can reach the VNet (see [Private Cluster](#feature-private-cluster-private_cluster_enabled)).
- **Permissive provider floors.** Provider constraints are `>=` floors (e.g. `azurerm >= 4.65`), not pinned ranges. This lets your root share one lock file across several modules without version conflicts. **Pin upper bounds in your own `.terraform.lock.hcl`** and commit it.

---

## Configuration

### Core inputs

Always set these on the module call:

| Input | Required | Default | Description |
|---|---|---|---|
| `subscription_id` | yes | — | Azure subscription ID, supplied by the root (e.g. `TF_VAR_subscription_id`) |
| `environment` | yes | — | `dev`, `stg`, `uat`, or `prod` |
| `region` | no | `eastus2` | Azure region |
| `project_name` | no | `optura` | Used in all resource names |
| `aks_admin_group_name` | no | `AKS Terraform Admins` | Azure AD group name for cluster admins |
| `aks_admin_group_id` | no | `null` | Set instead of `aks_admin_group_name` if your SP lacks `Group.Read.All` |
| `api_server_authorized_cidrs` | no | `[]` (open) | Restrict API access to specific CIDRs. Only applies when `private_cluster_enabled = false`; set it whenever you opt into a public API. |

### Feature: Database (`postgresql_enabled`)

Default: **`true`** — a PostgreSQL Flexible Server is created.

Set `postgresql_enabled = false` to skip. All `postgresql_*` inputs are ignored when disabled.

When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `postgresql_sku_name` | `GP_Standard_D2s_v3` | Instance SKU. Use `GP_Standard_D4s_v3` or higher for production. |
| `postgresql_storage_mb` | `131072` (128 GB) | Storage size in MB |
| `postgresql_ha_enabled` | `false` | Enable zone-redundant HA for production |
| `postgresql_backup_retention_days` | `7` | Days to retain backups (7–35) |
| `postgresql_admin_username` | `psqladmin` | Administrator username |

> **Post-deploy step — enable extensions.** After the first apply, enable the
> `vector` and `pg_trgm` extensions in the Azure portal:
> *Azure Database for PostgreSQL → your server → Settings → Server parameters →
> `azure.extensions` → select `vector` and `pg_trgm` → Save.* The module
> allow-lists the extensions on the server (`postgresql_extensions`, per-DB
> `extensions`), but the portal toggle is still required to load them.

#### Multiple named databases (`databases`)

The module provisions one Flexible Server per entry in `databases` (default: `core` only). Each map key becomes part of the server name:

- `core` is reserved for the primary server — its server keeps the unsuffixed name (`<project>-<env>-postgres`) so existing deployments do not destroy and recreate the production database.
- Every other key is suffixed (e.g. `<project>-<env>-postgres-temporal`).

Per-entry overrides (all optional) fall back to the top-level `postgresql_*` defaults when omitted:

```hcl
databases = {
  # core inherits all defaults — leave as {} to mirror the single-server config
  core = {}

  # temporal is sized independently and gets its own extensions allow-list
  temporal = {
    sku_name              = "GP_Standard_D2s_v3"
    storage_mb            = 32768 # 32 GB
    db_name               = "temporal"
    ha_enabled            = false
    extensions            = ["UUID-OSSP", "PGCRYPTO"]
    backup_retention_days = 7
  }
}
```

Supported per-entry fields: `sku_name`, `storage_mb`, `ha_enabled`, `zone`, `standby_availability_zone`, `backup_retention_days`, `geo_redundant_backup_enabled`, `admin_username`, `db_name`, `extensions`. A `{}` entry produces the same configuration as a legacy single-instance deployment. `extensions` is per-entry — each named server gets its own `azure.extensions` allow-list.

> **Validation:** `databases` MUST contain a `core` key. `core` maps to the state address `azurerm_postgresql_flexible_server.main["core"]`; removing it would destroy and recreate the production database, losing all data and rotating the admin password.

**Cost impact:** each named server is a full Flexible Server (compute, storage, encryption identity, Key Vault crypto role assignment). Adding a `temporal` entry roughly **doubles** the PostgreSQL line item. For dev, override the temporal sizing (smaller SKU, smaller storage) to keep costs down, or keep `databases = { core = {} }` if you don't need a second database.

**Outputs.** The singular outputs (`database_endpoint`, `database_admin_username`, `database_admin_password`, `database_name`, `database_server_name`, `database_address`, `database_port`) are **aliases for the `core` entry** — existing consumers see no change. For multi-DB consumers, the canonical outputs are maps keyed by `databases` key:

| Output | Type | Description |
|---|---|---|
| `database_endpoints` | `map(string)` | DB key → server FQDN |
| `database_names` | `map(string)` | DB key → initial database name |
| `database_admin_usernames` | `map(string)` (sensitive) | DB key → administrator username |
| `database_admin_passwords` | `map(string)` (sensitive) | DB key → administrator password |

```hcl
output "db_endpoints" {
  value = module.platform.database_endpoints
  # {
  #   "core"     = "optura-prod-postgres.privatelink.postgres.database.azure.com"
  #   "temporal" = "optura-prod-postgres-temporal.privatelink.postgres.database.azure.com"
  # }
}
```

The FQDNs are `privatelink.postgres.database.azure.com` hostnames — the servers have no public endpoint.

#### Upgrading from single-DB to multi-DB

Existing deployments upgrade with **zero destroys** thanks to `moved` blocks shipped in the module. After bumping the module `version` (or `?ref=`):

1. **Plan and inspect.** Confirm the plan shows state *moves* for the legacy server and *additions* for any new entry. Read every `# moved from .. to ..` line and confirm `azurerm_postgresql_flexible_server.main[0]` → `azurerm_postgresql_flexible_server.main["core"]` is present.

   Expected shape: `~moves, ~adds, ~replaces, 0 to destroy`. Some `core`-keyed *dependents* are intentionally renamed (physical names gain a `-core` suffix to avoid collisions as future keys are added):

   - `azurerm_user_assigned_identity.postgresql["core"]` — managed identity recreates; the server's `customer_managed_key.primary_user_assigned_identity_id` updates in place. Brief crypto-ops swap; server data persists.
   - `azurerm_role_assignment.kv_crypto_postgresql["core"]` — Key Vault role assignment recreates against the new identity principal.
   - `kubernetes_config_map.postgresql_ad_setup["core"]`, `kubernetes_secret.postgresql_bootstrap_creds["core"]`, `kubernetes_job_v1.postgresql_ad_bootstrap["core"]` — bootstrap re-runs idempotent Azure AD setup against the existing server.

   The server `azurerm_postgresql_flexible_server.main["core"]` itself is **not** replaced (the name ternary preserves its legacy unsuffixed name). If the plan shows it *destroyed* or *replaced*, **STOP and abort** — that would be data loss.

2. **Apply**, then verify both keys appear: `terraform output database_endpoints`.

#### Teleport access for named DBs (known limitation)

Each named database registers with the Teleport DB agent under a distinct name (`<project>-<env>-postgres-<key>` for non-core; `core` keeps the unsuffixed `<project>-<env>-postgres`), each with a Teleport `static_labels.db = <key>` field.

**However**, the default RBAC roles shipped by this module (`teleport-admins`, `teleport-viewers`) grant access to **all** registered databases — they are not scoped per-DB. Any user who can `tsh db connect optura-prod-postgres` can also connect to `optura-prod-postgres-temporal`. The `static_labels.db = <key>` field is the intended future hook for per-DB role restrictions (e.g. a Teleport role with `db_labels: { db: ["core"] }`); per-DB RBAC is a deliberate follow-up.

### Feature: Network (`create_vnet`)

Default: **`true`** — the module creates the VNet **and** the AKS, Application Gateway, and PostgreSQL subnets.

Set `create_vnet = false` to bring your own (BYO) network: the module creates **neither** the VNet **nor** the subnets, and you supply both. When `create_vnet = false`, set:

| Input | Required | Description |
|---|---|---|
| `existing_vnet_name` | yes | Name of the existing VNet |
| `existing_vnet_rg` | yes | Resource group of the existing VNet |
| `existing_aks_subnet_id` | yes | Full ARM resource ID of the existing AKS node subnet |
| `existing_appgw_subnet_id` | yes | Full ARM resource ID of the existing Application Gateway subnet |
| `existing_postgresql_subnet_id` | yes (when `postgresql_enabled = true`) | Full ARM resource ID of the existing PostgreSQL delegated subnet |

The `aks_subnet_address_prefix` / `appgw_subnet_address_prefix` / `postgresql_subnet_address_prefix` inputs apply only when `create_vnet = true`. In BYO mode they are ignored — subnets are referenced by ID, so their CIDRs are whatever you provisioned out of band.

#### Subnet requirements (`create_vnet = false`)

BYO subnets must satisfy the same shape the module would otherwise create:

- **PostgreSQL subnet** — **delegated** to `Microsoft.DBforPostgreSQL/flexibleServers` and **dedicated** (no other resources). A missing or shared delegation fails the apply.
- **AKS subnet** — with [overlay](#pod-networking-pod_cidr) (the default) it holds only nodes and private endpoints (a /26 fits ~20 nodes). With `pod_cidr = null`, each pod gets a VNet IP (31 per node at the default 30 pods), so plan a large range (**~/20**). Recommended service endpoints: `Microsoft.ContainerRegistry` and `Microsoft.Storage`.
- **Application Gateway subnet** — **dedicated** to the Application Gateway (App Gateway v2 requires its own subnet). With overlay (the default) it must also be **/24 or smaller** and **delegated** to `Microsoft.Network/applicationGateways`. The module cannot check a BYO subnet; a missing delegation shows up as AGIC failing to route to pods.

#### Required out-of-band RBAC (`create_vnet = false`)

When the module owns the VNet (`create_vnet = true`) it auto-creates the network role assignments. In BYO mode those are **skipped**, so grant them out of band:

- The **AKS cluster managed identity** needs **Network Contributor** on the **AKS subnet** (to manage NICs / load balancer rules).
- The **AGIC ingress identity** needs **Network Contributor** on the **Application Gateway subnet** (to program the gateway).

Without these the cluster and ingress controller cannot operate on the BYO subnets.

#### Pod networking (`pod_cidr`)

Default `100.64.0.0/16`: **Azure CNI Overlay**. Pods take IPs from `pod_cidr`, which is never routed: pod egress is SNAT'd to the node IP, and only the node subnet is visible to the network. Each node takes a /24 from the range, so the default /16 fits 256 nodes.

Override the range when it collides with your network, e.g. keeping pods and services in one confirmed-unused block:

```hcl
pod_cidr       = "100.64.128.0/17"
service_cidr   = "100.64.0.0/20"
dns_service_ip = "100.64.0.10"
```

Set `pod_cidr = null` for Azure CNI **without** overlay: every pod then takes an IP from the AKS subnet, so the subnet (and the routable VNet) must be large.

- `pod_cidr` must not overlap `service_cidr`, the VNet, or any peered / on-premises network (the first two are validated at plan time; a BYO VNet is checked at apply time).
- Choose it before the first apply: changing `pod_cidr` forces a new cluster.
- AGIC requirements for overlay: App Gateway subnet **/24 or smaller** (validated when `create_vnet = true`) and **delegated** to `Microsoft.Network/applicationGateways` (added by the module when `create_vnet = true`; add it yourself on a BYO subnet). The AKS-managed AGIC add-on must be v1.9.1 or later.

#### Dataplane (`network_data_plane`)

Default `null`: **Cilium** with overlay, the legacy **Azure** dataplane (Azure NPM) without. Cilium (Azure CNI Powered by Cilium) replaces kube-proxy and enforces `NetworkPolicy` in eBPF. Set `network_data_plane = "azure"` to keep overlay without Cilium. `"cilium"` requires overlay.

- `azure` → `cilium` updates in place, but reimages every node.
- `cilium` → `azure` forces a new cluster.
- Cilium has its own NetworkPolicy semantics: `ipBlock` rules don't match pod or node IPs. Use pod and namespace selectors for in-cluster traffic.
- Cilium supports Linux node pools only.
- FQDN and L7 policy, and Hubble flow logs, need Advanced Container Networking Services (paid). The module does not enable it.

#### Egress (`aks_outbound_type`)

Default `loadBalancer`: AKS creates a public IP on the cluster load balancer for node egress. Set `userDefinedRouting` to create no public IP and send egress through the AKS subnet's route table (e.g. `0.0.0.0/0` to a hub firewall). The route table must be associated with the AKS subnet **before** the cluster is created (so UDR requires `create_vnet = false`; a plan-time validation enforces it), and the firewall must allow the [AKS required outbound FQDNs](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress).

#### Service CIDR (`service_cidr` / `dns_service_ip`)

`service_cidr` (default `10.1.0.0/16`) is the Kubernetes **internal service** range; `dns_service_ip` (default `10.1.0.10`) is the cluster DNS service address and must sit inside `service_cidr`. `service_cidr` is virtual to the cluster and **must not overlap the VNet address space** (or any peered/on-prem range) — especially important against a centrally-managed BYO VNet. Both are validated at plan time.

#### Migrating an existing `create_vnet = false` deployment

> [!WARNING]
> This applies **only** if you previously ran a version of this module with
> `create_vnet = false` that silently *created* the AKS, Application Gateway, and
> (when `postgresql_enabled = true`) PostgreSQL subnets inside your existing VNet —
> it was not true BYO. Fresh deployments and `create_vnet = true` workspaces are
> unaffected.

With true BYO those subnets are consumed by ID, so on upgrade the `count` gate resolves to `0` and Terraform plans to **destroy** the subnets it used to manage (`azurerm_subnet.aks[0]`, `azurerm_subnet.appgw[0]`, and `azurerm_subnet.postgresql[0]` when PostgreSQL is on). A `moved` block cannot redirect a `count → 0` drop, and Azure rejects the deletion anyway (the AKS subnet has attached node NICs; the PostgreSQL subnet is delegated to a live server) — so the apply errors out rather than silently deleting. No data is lost, but the plan is blocked until you hand the subnets off to out-of-band ownership. Before applying the upgrade:

```bash
# 1. Drop the module-managed subnets from state WITHOUT destroying them in Azure.
#    (Address them under your module path, e.g. module.platform.azurerm_subnet.aks[0].)
terraform state rm \
  'module.platform.azurerm_subnet.aks[0]' \
  'module.platform.azurerm_subnet.appgw[0]' \
  'module.platform.azurerm_subnet.postgresql[0]'   # omit if postgresql_enabled = false

# 2. Point the BYO inputs at those same subnets (full ARM resource IDs):
#      existing_aks_subnet_id        = "/subscriptions/.../subnets/snet-aks-..."
#      existing_appgw_subnet_id      = "/subscriptions/.../subnets/snet-appgw-..."
#      existing_postgresql_subnet_id = "/subscriptions/.../subnets/snet-postgresql-..."
#
# 3. Grant the out-of-band RBAC above (AKS + AGIC Network Contributor), then
#    `terraform plan` — it should now show no subnet destroys.
```

The `byo_subnet_guard` precondition enforces step 2 (the plan fails if a required `existing_*_subnet_id` is null), the safety net against an accidental destroy-only apply.

### Feature: Logging Storage (`storage_logging_enabled`)

Default: **`true`** — an Azure Storage Account for centralized log storage. The logging workload's namespace and ServiceAccount come from the `logging` entry of [`workload_identities`](#workload-identity), not a dedicated input.

### Feature: General Storage (`storage_general_enabled`)

Default: **`true`** — a general storage account with two containers:

- `data` — generic application storage
- `documents` — backing store for application document/object storage

In-cluster services reach this account through [Workload Identity](#workload-identity). Configuration:

| Input | Default | Description |
|---|---|---|
| `storage_general_account_name` | `null` (→ `${project}${env}storage`) | Override the account name. 3–24 lowercase alphanumeric. |
| `storage_general_versioning` | `true` | Blob versioning. Default `true` for soft-deletion / overwrite recovery. |
| `storage_general_lifecycle_enabled` | `false` | Lifecycle on the `data` container only (tier-to-cool after 30d, delete after 90d). **Leave off** for persistent objects. |
| `storage_general_private_endpoint_enabled` | `true` | Private endpoint + privatelink DNS zone, so in-cluster traffic stays on the Azure backbone. Set `false` when `create_vnet = false` and privatelink DNS is managed centrally. |
| `storage_logging_private_endpoint_enabled` | `true` | Same, for the logging account. Shares the privatelink DNS zone. |
| `storage_public_network_access_enabled` | `false` | Public endpoint on **both** accounts. While `false`, each enabled account needs its private endpoint (validated at plan time). Must be `true` with a public App Gateway frontend (validated at plan time). |

> Permissions are scoped to the whole account — any federated SA can read/write every container. Cross-container isolation is enforced at the application layer.

> **Private by default.** Both accounts are reachable only through their private endpoints. Browser uploads through presigned URLs go to the private endpoint too: users' networks need a route to the AKS subnet and DNS that resolves `privatelink.blob.core.windows.net`. Terraform manages containers and lifecycle policies through the management plane, so applies are unaffected.
>
> With a **public** App Gateway frontend, users upload from the internet: set `storage_public_network_access_enabled = true`. Auth (Workload Identity or account keys) is then the gate.

## Workload Identity

`workload_identities` is a generic map for granting an in-cluster workload an Azure identity. One User-Assigned Managed Identity (UAMI) is created per map key, federated to a single ServiceAccount across N namespaces, with N Azure RBAC role assignments. Adding a workload's cloud identity is an input change, not new Terraform.

The **input default ships the platform identities** the current services need — you get them with no configuration (the exact set is in the [inputs table](#inputs) default; it changes as services do). The dynamic parts a Terraform default cannot hold — target resource IDs, the Foundry role-definition ID, a builtin's cluster-derived name — are resolved inside the module.

To run a service across multiple tenant namespaces sharing one storage account, set that entry's `namespaces` — one federated credential per namespace, all sharing the single UAMI and its role assignments. Per-tenant blob isolation is enforced at the application layer via `STORAGE_PREFIX=<namespace>` in each gitops overlay.

Annotate each ServiceAccount with the matching `client_id`, and use `principal_id` for RBAC granted from other repos:

```bash
terraform output -json workload_identities | jq -r '.["<identity-key>"].client_id'
```

### Schema

```hcl
workload_identities = {
  <key> = {
    namespaces      = list(string)     # one federated credential per namespace
    service_account = string           # the SA federated in every namespace
    name            = optional(string) # UAMI name override; default id-<project>-<env>-<key>-identity
    requires        = optional(string) # gate the whole identity on a feature flag (scope_ref enum value)
    role_assignments = optional(list(object({
      scope                = optional(string) # raw ARM resource ID (operator workloads)
      scope_ref            = optional(string) # symbolic: logging_storage | general_storage | foundry
      role_definition_name = optional(string) # by display name, or the "__foundry_user__" sentinel
      role_definition_id   = optional(string) # by definition ID
    })), [])
  }
}
```

Per `role_assignments` entry, set **exactly one** of `scope` / `scope_ref`, and **exactly one** of `role_definition_name` / `role_definition_id` (validations enforce both).

- **`scope_ref`** is a symbolic target resolved to a live resource ID in code: `logging_storage` (→ `storage_logging_enabled`), `general_storage` (→ `storage_general_enabled`), or `foundry` (→ `foundry_enabled`). Each maps to exactly its own flag — they're orthogonal, so `foundry` is usable by any workload, storage-bound or not. A role whose `scope_ref` flag is off is dropped; if that leaves an identity with no roles, the identity is dropped. Gating keys off the flag (a plan-known boolean), not the resolved ID, so greenfield applies don't hit "for_each keys can't be determined".
- **`scope`** is a raw ARM resource ID — typical for your own workloads, where you know the target up front.
- **`requires`** (optional, a `scope_ref` enum value) gates the **whole identity** on a feature flag, independently of its roles. Use it when an identity must track a flag even though one of its roles wouldn't be filtered — e.g. a storage-bound worker that also holds the flag-independent `foundry` role sets `requires = "general_storage"` so it is not created on a storage-off cluster. `null` = no gate.
- **`role_definition_name = "__foundry_user__"`** is a sentinel that expands to the Foundry User role by ID (its display name is unstable during the "Azure AI User" → "Foundry User" rename).

The UAMI's `client_id` (annotate the ServiceAccount with `azure.workload.identity/client-id`) and `principal_id` are stable across federated namespaces; permissions are granted once per UAMI and shared by every federated SA.

### Adding a workload — REPLACE semantics

Setting `workload_identities` **replaces** the default map (standard Terraform semantics). To add a workload, **start from the default map (see the [inputs table](#inputs) default) and append your entry** — otherwise you drop the platform identities.

Your appended entry typically uses a raw `scope` (you know the target up front):

```hcl
workload_identities = {
  # ... the existing default entries, copied verbatim ...

  reporting = {
    namespaces      = ["core"]
    service_account = "reporting"
    role_assignments = [
      {
        scope                = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<acct>"
        role_definition_name = "Storage Blob Data Reader"
      }
    ]
  }
}
```

This keeps the platform identities and adds one UAMI (`id-<project>-<env>-reporting-identity`), federates `core/reporting` into it, and grants Storage Blob Data Reader on the named account. Annotate the `reporting` ServiceAccount with the UAMI's `client_id` to activate it.

### Feature: Customer-Managed Keys (`enable_cmk`)

Default: **`true`** — a Premium Key Vault holds the keys for AKS disks, PostgreSQL, storage, and ACR. Set `false` for platform-managed keys (still AES-256 at rest) and no Key Vault.

The vault firewall is **deny-all**. Azure trusted services (the CMK consumers) bypass it; Terraform, which writes and reads the keys over the data plane, reaches it through the private endpoint or an allowed range:

| Input | Default | Description |
|---|---|---|
| `key_vault_private_endpoint_enabled` | `true` | Private endpoint + `privatelink.vaultcore.azure.net` zone. The runner's DNS must resolve that zone. Set `false` when it is managed centrally. |
| `key_vault_allowed_ip_ranges` | `[]` | Public IPs/CIDRs allowed through the firewall, e.g. a runner outside the VNet. Give a single IP as a bare address: Key Vault rejects /31 and /32. |

### Feature: Container Registry (`registry_enabled`)

Default: **`false`** — no ACR. Set `registry_enabled = true` to create one (Premium SKU by default). Access is **private by default**:

| Input | Default | Description |
|---|---|---|
| `acr_private_endpoint_enabled` | `true` | Private endpoint + `privatelink.azurecr.io` zone; nodes pull over it. Premium only. Set `false` when the zone is managed centrally. |
| `acr_allowed_ip_ranges` | `[]` | CIDRs allowed through a deny-all firewall on the public endpoint, e.g. a vendor CI that **pushes** images. Premium only. |
| `acr_public_network_enabled` | `false` | Open the public endpoint to **all** networks. Avoid; prefer `acr_allowed_ip_ranges`. |

ACR artifact cache supports only a fixed list of upstreams (Docker Hub, MCR, GHCR, Quay, ECR Public, Google Artifact Registry, and a few others). To fill the registry from any other registry, push into it from an allowed IP range, or copy images from inside the VNet (e.g. a `crane`/`skopeo` job) over the private endpoint.

### Feature: Registry Pull-Through Cache (`enable_registry_cache`)

Default: **`false`** — no pull-through cache. ACR itself is gated separately by `registry_enabled`.

Set `enable_registry_cache = true` to proxy an upstream registry through ACR. When enabled, also set:

| Input | Required | Description |
|---|---|---|
| `upstream_registry_url` | yes | Upstream registry URL (e.g. `registry.company.com`) |
| `upstream_registry_username` | yes | Set via `export TF_VAR_upstream_registry_username="..."` |
| `upstream_registry_password` | yes | Set via `export TF_VAR_upstream_registry_password="..."` |

### Feature: WAF on Application Gateway (`appgw_waf_enabled`)

Default: **`false`**. Requires `appgw_sku = "WAF_v2"`. Set both to enable the Web Application Firewall:

```hcl
appgw_sku         = "WAF_v2"
appgw_waf_enabled = true
```

When enabled, also configure `appgw_waf_firewall_mode` (default `Prevention`; `Detection` logs only, `Prevention` blocks).

### Feature: Cluster Access via Teleport (`access_mode`)

Default: **`teleport`** — the module deploys a Teleport agent. (`vpn` assumes an existing VPN or public endpoint.) When `access_mode = "teleport"`, configure:

| Input | Required | Description |
|---|---|---|
| `teleport_proxy_address` | yes | The Teleport proxy to connect to (e.g. `teleport.example.com:443`) |
| `teleport_agent_chart_repository` | yes | Helm repo for the teleport-kube-agent chart (e.g. `https://charts.releases.teleport.dev`, or an OCI mirror) |
| `teleport_agent_image` | no | Agent image; empty uses the chart's default |
| `teleport_join_token` | yes | Set via `export TF_VAR_teleport_join_token="..."` |
| `teleport_ca_pin` | recommended (prod) | CA pin for secure agent joining |
| `teleport_db_enabled` | `true` | Also enable Teleport database access. Requires `postgresql_enabled = true`. |

The module ships two RBAC roles: `teleport-admins` (full cluster access) and `teleport-viewers` (read-only).

### Feature: Private Cluster (`private_cluster_enabled`)

Default: **`true`** — the API server has no public endpoint.

Terraform must run from a host that can reach **and resolve** the private API (the private DNS zone AKS creates in the node resource group, `privatelink.<region>.azmk8s.io`). The module talks to the cluster during apply (Teleport agent, database bootstrap), so this applies to the **first** apply too:

- **A runner inside the VNet or a peered network** (VM, VDI, self-hosted CI runner or HCP Terraform agent on a VM). Its DNS must resolve `privatelink.<region>.azmk8s.io`, e.g. through Azure-provided DNS or a forwarder to 168.63.129.16. With `create_vnet = true`, the VNet is created in the same apply, so use `create_vnet = false` with a pre-built, reachable VNet.
- **Opt into a public API:** `private_cluster_enabled = false` with `api_server_authorized_cidrs` set to your runner's egress IPs.

> `private_cluster_enabled` **forces a new cluster** when changed. Choose it before the first apply; switching later destroys and recreates AKS.

#### In-cluster TFC agent (`tfc_agent_enabled`)

The in-cluster agent runs HCP Terraform plans from inside the cluster. It cannot bootstrap a private cluster: it only exists once the cluster does, and switching a public cluster to private recreates the cluster (and the agent with it). Use it with a public, CIDR-restricted API (`private_cluster_enabled = false`) when you want runs to originate inside the VNet. For a private cluster, run the HCP Terraform agent on a VM in the VNet instead.

```hcl
tfc_agent_enabled           = true
tfc_organization            = "my-org"
tfc_agent_pool_name         = "optura-dev-aks"
private_cluster_enabled     = false
api_server_authorized_cidrs = ["203.0.113.0/24"]
```

```bash
export TF_VAR_tfc_agent_token="your-hcp-terraform-api-token"
# apply, then verify the agent pod:
kubectl get pods -n terraform-cloud
```

Then set the workspace execution mode to **Agent** and select the pool above; later runs execute in-cluster (see [Module notes](#module-notes) on in-cluster auto-detection).

When `tfc_agent_enabled = true`, configure:

| Input | Required | Description |
|---|---|---|
| `tfc_agent_token` | yes | Set via `export TF_VAR_tfc_agent_token="..."` |
| `tfc_organization` | yes | Your HCP Terraform organization name |
| `tfc_agent_pool_name` | yes | Name for the agent pool |

### Feature: Azure AI Foundry (`foundry_enabled`)

Default: **`false`** — no Foundry resources.

Set `foundry_enabled = true` to provision a Foundry (AI Services) account, a private endpoint into the AKS subnet, and a UAMI federated to the in-cluster `intent` ServiceAccount. Model deployments (Claude, GPT, …) are created manually via the Foundry portal. When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `foundry_sku_name` | `S0` | SKU for the AI Services account. |
| `foundry_local_auth_enabled` | `false` | When `true`, the account also accepts key-based (API-key) data-plane auth alongside Entra ID. Default is AAD-only. Updates in place — the private endpoint / `network_acls` Deny still gate network reachability. |
| `foundry_location` | `null` (→ `region`) | Region for the Foundry account. Override when the chosen model family isn't available in your primary region — Foundry MaaS catalogs are region-gated during preview. |
| `foundry_private_dns_managed_externally` | `false` | When `true`, the module does NOT create or link the `privatelink.services.ai.azure.com` zone. Use with `create_vnet = false` when that zone is managed centrally — Azure rejects a second VNet link to a same-named zone. |
| `foundry_existing_private_dns_zone_id` | `null` | ARM ID of a centrally-managed `privatelink.services.ai.azure.com` zone the Foundry PE registers into. Only used when `foundry_private_dns_managed_externally = true`. Leave `null` to let central policy/DINE register the A record. |

> **Provisioning gate:**
> - `foundry_enabled = false` → nothing applied.
> - `foundry_enabled = true` → account, DNS zone, private endpoint, and UAMI are created. Model deployments are added separately via the Foundry portal.

The Foundry UAMI's `client_id` is exposed through the `workload_identities` output (the `intent` key). Annotate the `intent` ServiceAccount (in the `core` namespace by default) with `azure.workload.identity/client-id = <that client_id>`.

#### Foundry private DNS in a centrally-managed VNet

In the default deployment (`create_vnet = true`, or `create_vnet = false` with no central privatelink zone) leave both `foundry_private_dns_managed_externally` and `foundry_existing_private_dns_zone_id` unset — the module creates the `privatelink.services.ai.azure.com` zone, links it to the VNet, and registers the PE's A record.

When `create_vnet = false` against a centrally-managed VNet that already has that zone linked, Azure rejects a second VNet link to a same-named zone, so the local zone + link fail at apply. Set `foundry_private_dns_managed_externally = true` to skip them, then either:

- **Supply `foundry_existing_private_dns_zone_id`** — the PE registers its A record into the central zone via a DNS zone group (recommended when you can reference the central zone's ARM ID).
- **Leave it `null`** — the PE is created with no DNS zone group, and a central Azure Policy / DINE rule must register the A record.

> **⚠️ With `foundry_private_dns_managed_externally = true` and `foundry_existing_private_dns_zone_id = null`, you MUST have central DINE/policy register the endpoint's A record.** Without it the Foundry hostname resolves to the public FQDN, and because the account has `public_network_access_enabled = false`, the endpoint becomes **unreachable** — an availability failure, not a data-exposure risk.

## Upgrading to 1.0.0

1.0.0 makes every endpoint private by default and switches pod networking to Azure CNI Overlay with the Cilium dataplane. A 0.x workspace that upgrades without changes **plans to destroy and recreate the AKS cluster** (`private_cluster_enabled` and `pod_cidr` force a new resource). To keep 0.x behaviour, set these before upgrading, then adopt the private settings one at a time:

```hcl
private_cluster_enabled                  = false # REQUIRED to avoid cluster recreation
pod_cidr                                 = null  # REQUIRED: overlay is the 1.0.0 default (also keeps the Azure dataplane)
storage_public_network_access_enabled    = true
storage_general_private_endpoint_enabled = false # only if you had not opted in
storage_logging_private_endpoint_enabled = false
key_vault_private_endpoint_enabled       = false # with enable_cmk = true:
key_vault_allowed_ip_ranges              = ["<runner egress IP>"]   # firewall is now deny-all
acr_public_network_enabled               = true  # with registry_enabled = true
acr_private_endpoint_enabled             = false
```

What changes for a CMK workspace even with the settings above: the Key Vault firewall is now **deny-all** (Azure trusted services excepted). Terraform reads keys on every refresh, so the runner must reach the vault through the private endpoint or `key_vault_allowed_ip_ranges`. HCP Terraform's shared runners have no stable egress IPs; use an agent inside the VNet.

## Node Pools

Node pools are the `node_groups` map, keyed by pool name, in the same shape as the AWS module's `node_groups`. Adding a pool (for example **gpu**) is an input change, not a module change:

```hcl
node_groups = {
  system = {
    vm_size  = "Standard_D2as_v6"
    min_size = 1
    max_size = 5
    labels   = { "workload-type" = "system" }
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
```

- **`system`** is the cluster's system pool and is tainted `CriticalAddonsOnly`. Every other key is a user pool.
- **Sizing.** A pool autoscales between `min_size` and `max_size`, or runs at a fixed size when they are equal.
- **Names.** Keys and `temporary_name_for_rotation` must be lowercase alphanumeric, start with a letter and be at most 12 characters (validated). `temporary_name_for_rotation` defaults to the first 9 characters of the key plus `tmp`. Rotation names must be unique and must not match any pool name (validated).
- **Labels and taints.** The `node-pool` label is always set to the map key. Every entry **must** carry a `workload-type` label (validated), which workloads target via `nodeSelector`. Optional `taints` accept `{ key, value, effect }` objects (effect in Azure PascalCase, e.g. `NoSchedule`) rendered to Azure's `key=value:Effect` form.

## Database Access

The PostgreSQL servers have no public endpoint. Connect via a pod (the singular `database_endpoint` output resolves to the `core` server):

```bash
# Singular output — resolves to the "core" entry
kubectl run -it --rm psql --image=postgres:17 --restart=Never -- \
  psql -h $(terraform output -raw database_endpoint) -U psqladmin -d optura

# Multi-DB map output — pick a specific named DB
terraform output database_endpoints
# { "core" = "...", "temporal" = "..." }
```

Or via Teleport (when `access_mode = "teleport"` and `teleport_db_enabled = true`). Each entry in `databases` registers as a separate Teleport database:

```bash
tsh db ls
# Name                            Description  Labels
# optura-dev-postgres                          db=core,...
# optura-dev-postgres-temporal                 db=temporal,...

tsh db connect optura-dev-postgres --db-user=psqladmin --db-name=optura
tsh db connect optura-dev-postgres-temporal --db-user=psqladmin --db-name=temporal
```

> **Note on RBAC:** the default Teleport roles grant access to all registered databases — users who can connect to `core` can also connect to `temporal`. Per-DB RBAC via the `static_labels.db` selector is a planned follow-up.

## Push Images to ACR

Requires `registry_enabled = true`.

```bash
az acr login --name $(terraform output -raw registry_name)
docker tag myapp:latest $(terraform output -raw registry_url)/myapp:latest
docker push $(terraform output -raw registry_url)/myapp:latest
```

## Reference

The tables below are generated from the module source by `terraform-docs`. Do not hand-edit anything between the `BEGIN_TF_DOCS` / `END_TF_DOCS` markers.

<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | >= 3.6 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.65, < 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.1 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.38 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.12 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azuread"></a> [azuread](#provider\_azuread) | >= 3.6 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.65, < 5.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.1 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.38 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.12 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_application_gateway.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_cognitive_account.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_account) | resource |
| [azurerm_container_registry.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry) | resource |
| [azurerm_container_registry_scope_map.upstream](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_scope_map) | resource |
| [azurerm_container_registry_token.upstream](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_token) | resource |
| [azurerm_container_registry_token_password.upstream](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_token_password) | resource |
| [azurerm_disk_encryption_set.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/disk_encryption_set) | resource |
| [azurerm_federated_identity_credential.teleport_db_agent](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_federated_identity_credential.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_key_vault.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_key_vault_key.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) | resource |
| [azurerm_key_vault_key.aks_disk](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) | resource |
| [azurerm_key_vault_key.postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) | resource |
| [azurerm_key_vault_key.storage_general](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) | resource |
| [azurerm_key_vault_key.storage_logging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) | resource |
| [azurerm_kubernetes_cluster.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_postgresql_flexible_server.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server) | resource |
| [azurerm_postgresql_flexible_server_active_directory_administrator.teleport](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_active_directory_administrator) | resource |
| [azurerm_postgresql_flexible_server_configuration.extensions](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_configuration) | resource |
| [azurerm_postgresql_flexible_server_database.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_database) | resource |
| [azurerm_private_dns_zone.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone.blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone.key_vault](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone.postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_dns_zone_virtual_network_link.blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_dns_zone_virtual_network_link.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_dns_zone_virtual_network_link.key_vault](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_dns_zone_virtual_network_link.postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_private_endpoint.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_private_endpoint.key_vault](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_private_endpoint.storage_blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_private_endpoint.storage_logging_blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_public_ip.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_resource_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.agic_appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_identity_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_subnet](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_acr_pull](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_des_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_des_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_admin_current_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_crypto_acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_crypto_disk_encryption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_crypto_postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_crypto_storage_general](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_crypto_storage_logging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kv_secrets_acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_security_center_subscription_pricing.container_registry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_subscription_pricing) | resource |
| [azurerm_storage_account.logging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_account.storage](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.documents](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_container.logging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_container.storage](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_management_policy.logging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy) | resource |
| [azurerm_storage_management_policy.storage](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_user_assigned_identity.acr_encryption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.disk_encryption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.postgresql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.storage_general_encryption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.storage_logging_encryption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.teleport_db_agent](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [azurerm_web_application_firewall_policy.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/web_application_firewall_policy) | resource |
| [helm_release.teleport_kube_agent](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.postgresql_ad_setup](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.postgresql_bootstrap_creds](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_admin_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_admin_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_viewer_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_viewer_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_cluster_role_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_service_account](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_token](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_job_v1.postgresql_ad_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [random_password.postgresql_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.byo_subnet_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.postgresql_ad_setup_hash](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.teleport_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.tfc_agent_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [time_sleep.key_vault_ready](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.wait_for_foundry_account](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azuread_group.aks_admins](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/group) | data source |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_virtual_network.existing](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/virtual_network) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_mode"></a> [access\_mode](#input\_access\_mode) | K8s API access mode (teleport or vpn) | `string` | `"teleport"` | no |
| <a name="input_acr_allowed_ip_ranges"></a> [acr\_allowed\_ip\_ranges](#input\_acr\_allowed\_ip\_ranges) | CIDRs allowed through the ACR firewall on the public endpoint (e.g. a vendor CI that pushes images). When non-empty, the public endpoint is enabled with default\_action = Deny and only these ranges allowed. Premium SKU only. | `list(string)` | `[]` | no |
| <a name="input_acr_private_endpoint_enabled"></a> [acr\_private\_endpoint\_enabled](#input\_acr\_private\_endpoint\_enabled) | Create a private endpoint + privatelink.azurecr.io DNS zone for ACR, linked to the VNet. Premium SKU only. Set false when privatelink.azurecr.io is managed centrally and register the endpoint out-of-band. | `bool` | `true` | no |
| <a name="input_acr_public_network_enabled"></a> [acr\_public\_network\_enabled](#input\_acr\_public\_network\_enabled) | Open the ACR public endpoint to all networks. Default false: the registry is reachable only through its private endpoint, plus acr\_allowed\_ip\_ranges when set. | `bool` | `false` | no |
| <a name="input_acr_sku"></a> [acr\_sku](#input\_acr\_sku) | ACR SKU (Basic, Standard, Premium) | `string` | `"Premium"` | no |
| <a name="input_acr_zone_redundancy_enabled"></a> [acr\_zone\_redundancy\_enabled](#input\_acr\_zone\_redundancy\_enabled) | Enable zone redundancy for ACR (Premium SKU only) | `bool` | `true` | no |
| <a name="input_aks_admin_group_id"></a> [aks\_admin\_group\_id](#input\_aks\_admin\_group\_id) | Azure AD group Object ID for AKS cluster admins (bypasses group lookup, useful when SP lacks Group.Read.All) | `string` | `null` | no |
| <a name="input_aks_admin_group_name"></a> [aks\_admin\_group\_name](#input\_aks\_admin\_group\_name) | Azure AD group name for AKS cluster admins (ignored if aks\_admin\_group\_id is set) | `string` | `"AKS Terraform Admins"` | no |
| <a name="input_aks_outbound_type"></a> [aks\_outbound\_type](#input\_aks\_outbound\_type) | AKS egress method. "loadBalancer" (default) gives nodes a public egress IP on the cluster load balancer. "userDefinedRouting" creates no public IP: egress follows the AKS subnet's route table (e.g. 0.0.0.0/0 to a hub firewall), which must be associated with the subnet before the cluster is created, so it requires create\_vnet = false (BYO subnet). Changing it on an existing cluster may force replacement. | `string` | `"loadBalancer"` | no |
| <a name="input_aks_subnet_address_prefix"></a> [aks\_subnet\_address\_prefix](#input\_aks\_subnet\_address\_prefix) | Address prefix for AKS subnet | `string` | `"10.0.0.0/20"` | no |
| <a name="input_api_server_authorized_cidrs"></a> [api\_server\_authorized\_cidrs](#input\_api\_server\_authorized\_cidrs) | Authorized CIDR blocks for API server access (only applies when private\_cluster\_enabled = false, empty = open) | `list(string)` | `[]` | no |
| <a name="input_appgw_capacity_max"></a> [appgw\_capacity\_max](#input\_appgw\_capacity\_max) | Maximum capacity units for Application Gateway autoscaling | `number` | `10` | no |
| <a name="input_appgw_capacity_min"></a> [appgw\_capacity\_min](#input\_appgw\_capacity\_min) | Minimum capacity units for Application Gateway autoscaling | `number` | `2` | no |
| <a name="input_appgw_enable_http2"></a> [appgw\_enable\_http2](#input\_appgw\_enable\_http2) | Enable HTTP/2 on Application Gateway | `bool` | `true` | no |
| <a name="input_appgw_frontend_type"></a> [appgw\_frontend\_type](#input\_appgw\_frontend\_type) | App Gateway frontend exposure:<br/>  - "private" (default): private IP frontend only, no public IP. Ingress is<br/>    reachable only from within the VNet/peered networks (hub-and-spoke).<br/>    Requires the Microsoft.Network/EnableApplicationGatewayNetworkIsolation<br/>    feature registered on the subscription, and ingresses annotated<br/>    appgw.ingress.kubernetes.io/use-private-ip: "true".<br/>  - "public": public IP frontend only.<br/>  - "both": public and private frontends.<br/>For "private"/"both", the private IP comes from appgw\_private\_ip\_address; when<br/>create\_vnet = true it is auto-derived from appgw\_subnet\_address\_prefix if unset.<br/><br/>NOTE: changing this on an EXISTING gateway is not an in-place operation —<br/>AGIC owns the listeners (lifecycle ignore\_changes on http\_listener), so a<br/>sticky listener can still reference the removed frontend and fail the apply.<br/>Recreate the gateway (terraform apply -replace=...azurerm\_application\_gateway.main)<br/>when switching frontend type. | `string` | `"private"` | no |
| <a name="input_appgw_private_ip_address"></a> [appgw\_private\_ip\_address](#input\_appgw\_private\_ip\_address) | Static private IP for the App Gateway private frontend. Required for "private"/"both" when create\_vnet = false (BYO subnet); when create\_vnet = true it defaults to host .10 of appgw\_subnet\_address\_prefix. Must be a free address inside the App Gateway subnet. | `string` | `null` | no |
| <a name="input_appgw_sku"></a> [appgw\_sku](#input\_appgw\_sku) | Application Gateway SKU (Standard\_v2 or WAF\_v2) | `string` | `"Standard_v2"` | no |
| <a name="input_appgw_subnet_address_prefix"></a> [appgw\_subnet\_address\_prefix](#input\_appgw\_subnet\_address\_prefix) | Address prefix for Application Gateway subnet | `string` | `"10.0.16.0/24"` | no |
| <a name="input_appgw_waf_enabled"></a> [appgw\_waf\_enabled](#input\_appgw\_waf\_enabled) | Enable WAF (only applicable with WAF\_v2 SKU) | `bool` | `false` | no |
| <a name="input_appgw_waf_firewall_mode"></a> [appgw\_waf\_firewall\_mode](#input\_appgw\_waf\_firewall\_mode) | WAF firewall mode (Detection or Prevention) | `string` | `"Prevention"` | no |
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | Availability zones for AKS nodes | `list(string)` | <pre>[<br/>  "1",<br/>  "3"<br/>]</pre> | no |
| <a name="input_create_vnet"></a> [create\_vnet](#input\_create\_vnet) | Create new VNet (true) or use existing (false) | `bool` | `true` | no |
| <a name="input_databases"></a> [databases](#input\_databases) | Map of named PostgreSQL Flexible Server instances to provision when<br/>postgresql\_enabled = true. Each map key becomes part of the server name<br/>(the special key "core" preserves the legacy unsuffixed server name for<br/>backward compatibility). Per-entry fields fall back to the top-level<br/>var.postgresql\_* defaults when omitted. | <pre>map(object({<br/>    sku_name                     = optional(string)<br/>    storage_mb                   = optional(number)<br/>    ha_enabled                   = optional(bool)<br/>    zone                         = optional(string)<br/>    standby_availability_zone    = optional(string)<br/>    backup_retention_days        = optional(number)<br/>    geo_redundant_backup_enabled = optional(bool)<br/>    admin_username               = optional(string)<br/>    db_name                      = optional(string)<br/>    extensions                   = optional(list(string))<br/>  }))</pre> | <pre>{<br/>  "core": {}<br/>}</pre> | no |
| <a name="input_dns_service_ip"></a> [dns\_service\_ip](#input\_dns\_service\_ip) | Cluster DNS service IP. Must fall inside service\_cidr. | `string` | `"10.1.0.10"` | no |
| <a name="input_enable_cmk"></a> [enable\_cmk](#input\_enable\_cmk) | Use customer-managed keys (CMK) for encryption. When false, Azure uses platform-managed keys (PMK) instead — data is still AES-256 encrypted at rest, Azure just manages the key. Set to false for subscription transfers to eliminate Key Vault and encryption identity dependencies. | `bool` | `true` | no |
| <a name="input_enable_defender_for_containers"></a> [enable\_defender\_for\_containers](#input\_enable\_defender\_for\_containers) | Enable Microsoft Defender for Container registry scanning | `bool` | `true` | no |
| <a name="input_enable_registry_cache"></a> [enable\_registry\_cache](#input\_enable\_registry\_cache) | Enable pull-through cache from upstream registry | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (dev, stg, uat, prod) | `string` | n/a | yes |
| <a name="input_existing_aks_subnet_id"></a> [existing\_aks\_subnet\_id](#input\_existing\_aks\_subnet\_id) | Full ARM resource ID of a pre-created AKS subnet (/subscriptions/.../subnets/...). Only used if create\_vnet=false. The subnet must be sized for Azure CNI and the AKS cluster identity must be granted Network Contributor on it out-of-band. | `string` | `null` | no |
| <a name="input_existing_appgw_subnet_id"></a> [existing\_appgw\_subnet\_id](#input\_existing\_appgw\_subnet\_id) | Full ARM resource ID of a pre-created Application Gateway subnet. Only used if create\_vnet=false. Must be dedicated to the App Gateway and the AGIC identity must be granted Network Contributor on it out-of-band. | `string` | `null` | no |
| <a name="input_existing_postgresql_subnet_id"></a> [existing\_postgresql\_subnet\_id](#input\_existing\_postgresql\_subnet\_id) | Full ARM resource ID of a pre-created, delegated PostgreSQL subnet. Only used if create\_vnet=false and postgresql\_enabled=true. Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers and dedicated. | `string` | `null` | no |
| <a name="input_existing_vnet_name"></a> [existing\_vnet\_name](#input\_existing\_vnet\_name) | Name of existing VNet (only used if create\_vnet=false) | `string` | `null` | no |
| <a name="input_existing_vnet_rg"></a> [existing\_vnet\_rg](#input\_existing\_vnet\_rg) | Resource group of existing VNet (only used if create\_vnet=false) | `string` | `null` | no |
| <a name="input_foundry_enabled"></a> [foundry\_enabled](#input\_foundry\_enabled) | Provision the Azure AI Foundry module (account, private endpoint, and intent workload identity) | `bool` | `false` | no |
| <a name="input_foundry_existing_private_dns_zone_id"></a> [foundry\_existing\_private\_dns\_zone\_id](#input\_foundry\_existing\_private\_dns\_zone\_id) | ARM resource ID of a centrally-managed privatelink.services.ai.azure.com DNS zone the Foundry private endpoint should register into. Only used when foundry\_private\_dns\_managed\_externally=true. Leave null to let central policy/DINE handle A-record registration. | `string` | `null` | no |
| <a name="input_foundry_local_auth_enabled"></a> [foundry\_local\_auth\_enabled](#input\_foundry\_local\_auth\_enabled) | Whether the Foundry account accepts key-based (API-key) data-plane auth in addition to Entra ID (AAD). Default false — AAD-only, the intent workload identity is the sole caller. Set true when a consumer needs the account keys. Updates in place (not ForceNew); network restrictions (private endpoint, network\_acls Deny, public access off) are unaffected. | `bool` | `false` | no |
| <a name="input_foundry_location"></a> [foundry\_location](#input\_foundry\_location) | Region for the Foundry account. Defaults to the resource group location. Override when Claude (or another model family) is not available in the stack's primary region — Foundry MaaS catalogs are region-gated during preview. | `string` | `null` | no |
| <a name="input_foundry_private_dns_managed_externally"></a> [foundry\_private\_dns\_managed\_externally](#input\_foundry\_private\_dns\_managed\_externally) | When true, Terraform does NOT create or link the privatelink.services.ai.azure.com private DNS zone. Use when create\_vnet=false and your environment manages this privatelink zone centrally — Azure rejects a second VNet link to a zone of the same name. The Foundry private endpoint then registers into foundry\_existing\_private\_dns\_zone\_id (if set) or omits its DNS zone group entirely (central policy/DINE handles registration). | `bool` | `false` | no |
| <a name="input_foundry_project_management_enabled"></a> [foundry\_project\_management\_enabled](#input\_foundry\_project\_management\_enabled) | Whether the Foundry account has AI Foundry project management enabled. ForceNew — changing it recreates the account (soft-delete purge risk; cascades to the private endpoint and all foundry-scoped role assignments). Default false; set true only for environments whose account was created with it enabled so their plan does not force a replace. | `bool` | `false` | no |
| <a name="input_foundry_sku_name"></a> [foundry\_sku\_name](#input\_foundry\_sku\_name) | SKU for the Azure AI Foundry (AI Services) account | `string` | `"S0"` | no |
| <a name="input_key_vault_allowed_ip_ranges"></a> [key\_vault\_allowed\_ip\_ranges](#input\_key\_vault\_allowed\_ip\_ranges) | Public IPs/CIDRs allowed through the CMK Key Vault firewall (e.g. a Terraform runner outside the VNet). Give a single IP as a bare address (1.2.3.4): Key Vault rejects /31 and /32. Default empty: public traffic is denied except Azure trusted services. | `list(string)` | `[]` | no |
| <a name="input_key_vault_private_endpoint_enabled"></a> [key\_vault\_private\_endpoint\_enabled](#input\_key\_vault\_private\_endpoint\_enabled) | Create a private endpoint + privatelink.vaultcore.azure.net DNS zone for the CMK Key Vault (enable\_cmk = true), linked to the VNet. Default true. The vault firewall always denies public traffic except Azure trusted services and key\_vault\_allowed\_ip\_ranges, so Terraform must reach the vault through this endpoint or an allowed range. Set false when privatelink.vaultcore.azure.net is managed centrally. | `bool` | `true` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version | `string` | `"1.35"` | no |
| <a name="input_network_data_plane"></a> [network\_data\_plane](#input\_network\_data\_plane) | AKS network dataplane. null (default): "cilium" with overlay (pod\_cidr set), "azure" without. "cilium": Azure CNI Powered by Cilium, eBPF dataplane without kube-proxy, Cilium network policy; requires overlay. "azure": legacy dataplane with Azure network policy; use it to keep overlay without Cilium. Switching azure -> cilium upgrades in place (reimages every node); cilium -> azure forces a new cluster. | `string` | `null` | no |
| <a name="input_node_groups"></a> [node\_groups](#input\_node\_groups) | AKS node pools keyed by name. "system" is the cluster's system pool; every other key is a user pool. A pool autoscales between min\_size and max\_size, or is fixed at that size when they are equal. | <pre>map(object({<br/>    vm_size                     = string<br/>    min_size                    = number<br/>    max_size                    = number<br/>    disk_size                   = optional(number, 128)<br/>    temporary_name_for_rotation = optional(string)<br/>    labels                      = map(string)<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = string<br/>      effect = string # Azure expects PascalCase: NoSchedule | PreferNoSchedule | NoExecute<br/>    })), [])<br/>  }))</pre> | <pre>{<br/>  "application": {<br/>    "disk_size": 256,<br/>    "labels": {<br/>      "workload-type": "application"<br/>    },<br/>    "max_size": 3,<br/>    "min_size": 1,<br/>    "temporary_name_for_rotation": "apptmp",<br/>    "vm_size": "Standard_D4as_v7"<br/>  },<br/>  "support": {<br/>    "disk_size": 128,<br/>    "labels": {<br/>      "workload-type": "support"<br/>    },<br/>    "max_size": 3,<br/>    "min_size": 1,<br/>    "temporary_name_for_rotation": "supprttmp",<br/>    "vm_size": "Standard_E2as_v7"<br/>  },<br/>  "system": {<br/>    "disk_size": 128,<br/>    "labels": {<br/>      "workload-type": "system"<br/>    },<br/>    "max_size": 3,<br/>    "min_size": 3,<br/>    "vm_size": "Standard_D2s_v6"<br/>  }<br/>}</pre> | no |
| <a name="input_pod_cidr"></a> [pod\_cidr](#input\_pod\_cidr) | Pod IP range for Azure CNI Overlay (the default). Pods take IPs from this<br/>range instead of the AKS subnet, the range is never routed (pod egress is<br/>SNAT'd to the node IP), and the AKS subnet only needs to hold nodes and<br/>private endpoints. Each node takes a /24 from the range, so the default<br/>/16 fits 256 nodes. Must not overlap service\_cidr, the VNet, or any<br/>peered / on-premises network. Set null for Azure CNI without overlay<br/>(pods take VNet IPs; size the AKS subnet for it).<br/><br/>Set it before the first apply: changing it forces a new cluster. With<br/>overlay, the App Gateway subnet must be /24 or smaller and delegated to<br/>Microsoft.Network/applicationGateways (the module adds the delegation<br/>when create\_vnet = true; do it yourself on a BYO subnet). | `string` | `"100.64.0.0/16"` | no |
| <a name="input_postgresql_admin_username"></a> [postgresql\_admin\_username](#input\_postgresql\_admin\_username) | PostgreSQL administrator username | `string` | `"psqladmin"` | no |
| <a name="input_postgresql_backup_retention_days"></a> [postgresql\_backup\_retention\_days](#input\_postgresql\_backup\_retention\_days) | PostgreSQL backup retention in days | `number` | `7` | no |
| <a name="input_postgresql_enabled"></a> [postgresql\_enabled](#input\_postgresql\_enabled) | Deploy PostgreSQL Flexible Server | `bool` | `true` | no |
| <a name="input_postgresql_extensions"></a> [postgresql\_extensions](#input\_postgresql\_extensions) | PostgreSQL extensions to allow-list on Azure Flexible Server | `list(string)` | <pre>[<br/>  "VECTOR",<br/>  "PG_TRGM",<br/>  "UUID-OSSP",<br/>  "PGCRYPTO"<br/>]</pre> | no |
| <a name="input_postgresql_ha_enabled"></a> [postgresql\_ha\_enabled](#input\_postgresql\_ha\_enabled) | Enable zone-redundant high availability for PostgreSQL | `bool` | `false` | no |
| <a name="input_postgresql_sku_name"></a> [postgresql\_sku\_name](#input\_postgresql\_sku\_name) | PostgreSQL SKU (e.g., GP\_Standard\_D2s\_v3, MO\_Standard\_E4s\_v3) | `string` | `"GP_Standard_D2s_v3"` | no |
| <a name="input_postgresql_storage_mb"></a> [postgresql\_storage\_mb](#input\_postgresql\_storage\_mb) | PostgreSQL storage size in MB | `number` | `131072` | no |
| <a name="input_postgresql_subnet_address_prefix"></a> [postgresql\_subnet\_address\_prefix](#input\_postgresql\_subnet\_address\_prefix) | Address prefix for PostgreSQL subnet | `string` | `"10.0.17.0/24"` | no |
| <a name="input_postgresql_version"></a> [postgresql\_version](#input\_postgresql\_version) | PostgreSQL version | `string` | `"17"` | no |
| <a name="input_private_cluster_enabled"></a> [private\_cluster\_enabled](#input\_private\_cluster\_enabled) | Private cluster API (no public endpoint). Default true. Terraform must run from a host that can reach and resolve the private API: a runner inside the VNet or a peered network (e.g. an HCP Terraform agent on a VM). The in-cluster TFC agent cannot bootstrap a private cluster. Set false (with api\_server\_authorized\_cidrs) to opt into a public API. Changing this forces a new cluster. | `bool` | `true` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming | `string` | `"optura"` | no |
| <a name="input_region"></a> [region](#input\_region) | Azure region for all resources | `string` | `"eastus2"` | no |
| <a name="input_registry_enabled"></a> [registry\_enabled](#input\_registry\_enabled) | Deploy Azure Container Registry | `bool` | `false` | no |
| <a name="input_service_cidr"></a> [service\_cidr](#input\_service\_cidr) | In-cluster ClusterIP service range for AKS (Azure CNI). Must NOT overlap the VNet address space or any subnet — critical when create\_vnet=false and the VNet is centrally managed. | `string` | `"10.1.0.0/16"` | no |
| <a name="input_storage_general_account_name"></a> [storage\_general\_account\_name](#input\_storage\_general\_account\_name) | Override storage account name for general storage (default: {project}{environment}storage). Used to dodge Azure's ~14-day global name reservation when redeploying. Must be 3-24 lowercase alphanumeric chars. | `string` | `null` | no |
| <a name="input_storage_general_cors_origins"></a> [storage\_general\_cors\_origins](#input\_storage\_general\_cors\_origins) | Browser origins allowed to call the general storage account directly (presigned uploads). Empty disables CORS, which blocks every browser upload. | `list(string)` | `[]` | no |
| <a name="input_storage_general_enabled"></a> [storage\_general\_enabled](#input\_storage\_general\_enabled) | Deploy general storage account | `bool` | `true` | no |
| <a name="input_storage_general_lifecycle_enabled"></a> [storage\_general\_lifecycle\_enabled](#input\_storage\_general\_lifecycle\_enabled) | Enable lifecycle management for general storage | `bool` | `false` | no |
| <a name="input_storage_general_private_endpoint_enabled"></a> [storage\_general\_private\_endpoint\_enabled](#input\_storage\_general\_private\_endpoint\_enabled) | Provision a private endpoint + privatelink.blob.core.windows.net DNS<br/>zone for the general storage blob endpoint, linked to the AKS VNet.<br/>In-cluster traffic resolves the storage hostname to the PE's private<br/>IP and stays on the Azure backbone. Default true.<br/><br/>Set false when `create_vnet = false` and your environment manages<br/>privatelink.blob.core.windows.net centrally — Azure rejects multiple<br/>VNet links to zones of the same name, and the PE's DNS record has to<br/>be added to the central zone out-of-band. | `bool` | `true` | no |
| <a name="input_storage_general_versioning"></a> [storage\_general\_versioning](#input\_storage\_general\_versioning) | Enable blob versioning on the general storage account. Defaults to true so the primary consumer benefits from soft-deletion / accidental-overwrite recovery. | `bool` | `true` | no |
| <a name="input_storage_logging_account_name"></a> [storage\_logging\_account\_name](#input\_storage\_logging\_account\_name) | Override storage account name for logging storage (default: {project}{environment}logging). Used to dodge Azure's ~14-day global name reservation when redeploying. Must be 3-24 lowercase alphanumeric chars. | `string` | `null` | no |
| <a name="input_storage_logging_enabled"></a> [storage\_logging\_enabled](#input\_storage\_logging\_enabled) | Deploy logging storage account | `bool` | `true` | no |
| <a name="input_storage_logging_lifecycle"></a> [storage\_logging\_lifecycle](#input\_storage\_logging\_lifecycle) | Lifecycle policy for logging storage | <pre>object({<br/>    transition_to_cool_days    = number<br/>    transition_to_archive_days = number<br/>    expiration_days            = number<br/>  })</pre> | <pre>{<br/>  "expiration_days": 365,<br/>  "transition_to_archive_days": 90,<br/>  "transition_to_cool_days": 30<br/>}</pre> | no |
| <a name="input_storage_logging_private_endpoint_enabled"></a> [storage\_logging\_private\_endpoint\_enabled](#input\_storage\_logging\_private\_endpoint\_enabled) | Provision a private endpoint for the logging storage blob endpoint, registered in the same privatelink.blob.core.windows.net zone as the general storage endpoint. Default true. Same central-DNS caveat as storage\_general\_private\_endpoint\_enabled. | `bool` | `true` | no |
| <a name="input_storage_public_network_access_enabled"></a> [storage\_public\_network\_access\_enabled](#input\_storage\_public\_network\_access\_enabled) | Allow public network access to the logging and general storage accounts. Default false: they are reachable only through their private endpoints, so every enabled account needs its private endpoint, and browser uploads via presigned URLs need a private network path (and privatelink DNS) to the endpoint. Set true for a public App Gateway frontend. | `bool` | `false` | no |
| <a name="input_subscription_id"></a> [subscription\_id](#input\_subscription\_id) | Azure subscription ID | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Common tags applied to all resources | `map(string)` | `{}` | no |
| <a name="input_teleport_agent_chart_repository"></a> [teleport\_agent\_chart\_repository](#input\_teleport\_agent\_chart\_repository) | Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access\_mode = teleport — supply your own. | `string` | `""` | no |
| <a name="input_teleport_agent_image"></a> [teleport\_agent\_image](#input\_teleport\_agent\_image) | Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters). | `string` | `""` | no |
| <a name="input_teleport_ca_pin"></a> [teleport\_ca\_pin](#input\_teleport\_ca\_pin) | Teleport CA pin (optional, recommended for prod) | `string` | `null` | no |
| <a name="input_teleport_db_enabled"></a> [teleport\_db\_enabled](#input\_teleport\_db\_enabled) | Enable Teleport database service for PostgreSQL | `bool` | `true` | no |
| <a name="input_teleport_gateway_ip"></a> [teleport\_gateway\_ip](#input\_teleport\_gateway\_ip) | Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP. | `string` | `null` | no |
| <a name="input_teleport_join_token"></a> [teleport\_join\_token](#input\_teleport\_join\_token) | Teleport agent join token (used for all services: kube, app, db, discovery) | `string` | `null` | no |
| <a name="input_teleport_proxy_address"></a> [teleport\_proxy\_address](#input\_teleport\_proxy\_address) | Teleport proxy address as host:port (required when access\_mode = teleport). Defaults to empty — supply your own Teleport proxy. | `string` | `""` | no |
| <a name="input_teleport_version"></a> [teleport\_version](#input\_teleport\_version) | Teleport version | `string` | `"18.5.1"` | no |
| <a name="input_tfc_agent_enabled"></a> [tfc\_agent\_enabled](#input\_tfc\_agent\_enabled) | Deploy Terraform Cloud Agent for private cluster access | `bool` | `false` | no |
| <a name="input_tfc_agent_token"></a> [tfc\_agent\_token](#input\_tfc\_agent\_token) | Terraform Cloud Agent token (sensitive, set via TF\_VAR\_tfc\_agent\_token) | `string` | `null` | no |
| <a name="input_tfc_agent_version"></a> [tfc\_agent\_version](#input\_tfc\_agent\_version) | TFC Agent container image tag | `string` | `"1.28.5"` | no |
| <a name="input_upstream_registry_password"></a> [upstream\_registry\_password](#input\_upstream\_registry\_password) | Password for upstream registry authentication | `string` | `null` | no |
| <a name="input_upstream_registry_url"></a> [upstream\_registry\_url](#input\_upstream\_registry\_url) | Upstream registry URL for cache (e.g., registry.company.com) | `string` | `null` | no |
| <a name="input_upstream_registry_username"></a> [upstream\_registry\_username](#input\_upstream\_registry\_username) | Username for upstream registry authentication | `string` | `null` | no |
| <a name="input_vnet_address_space"></a> [vnet\_address\_space](#input\_vnet\_address\_space) | Address space for VNet (only used if create\_vnet=true) | `list(string)` | <pre>[<br/>  "10.0.0.0/16"<br/>]</pre> | no |
| <a name="input_vpn_gateway_ips"></a> [vpn\_gateway\_ips](#input\_vpn\_gateway\_ips) | VPN gateway IPs (legacy, for vpn mode) | `list(string)` | `[]` | no |
| <a name="input_workload_identities"></a> [workload\_identities](#input\_workload\_identities) | AKS Workload Identity map: one UAMI per key, federated to a ServiceAccount across namespaces, with Azure RBAC role assignments. scope\_ref values are resolved to live resource IDs in azure/workload-identity.tf. | <pre>map(object({<br/>    namespaces      = list(string)<br/>    service_account = string<br/>    name            = optional(string) # UAMI name override; default id-<prefix>-<key>-identity (logging is special-cased in code)<br/>    requires        = optional(string) # gate: only create this identity when the named target's feature flag is on (scope_ref enum value)<br/>    role_assignments = optional(list(object({<br/>      scope                = optional(string) # raw ARM resource ID<br/>      scope_ref            = optional(string) # symbolic: logging_storage | general_storage | foundry<br/>      role_definition_name = optional(string) # or the "__foundry_user__" sentinel<br/>      role_definition_id   = optional(string)<br/>    })), [])<br/>  }))</pre> | <pre>{<br/>  "documents": {<br/>    "namespaces": [<br/>      "core"<br/>    ],<br/>    "requires": "general_storage",<br/>    "role_assignments": [<br/>      {<br/>        "role_definition_name": "Storage Blob Data Contributor",<br/>        "scope_ref": "general_storage"<br/>      }<br/>    ],<br/>    "service_account": "documents"<br/>  },<br/>  "documents-processing": {<br/>    "namespaces": [<br/>      "core"<br/>    ],<br/>    "requires": "general_storage",<br/>    "role_assignments": [<br/>      {<br/>        "role_definition_name": "Storage Blob Data Contributor",<br/>        "scope_ref": "general_storage"<br/>      },<br/>      {<br/>        "role_definition_name": "__foundry_user__",<br/>        "scope_ref": "foundry"<br/>      }<br/>    ],<br/>    "service_account": "documents-processing"<br/>  },<br/>  "intent": {<br/>    "namespaces": [<br/>      "core"<br/>    ],<br/>    "requires": "foundry",<br/>    "role_assignments": [<br/>      {<br/>        "role_definition_name": "__foundry_user__",<br/>        "scope_ref": "foundry"<br/>      }<br/>    ],<br/>    "service_account": "intent"<br/>  },<br/>  "logging": {<br/>    "namespaces": [<br/>      "monitoring"<br/>    ],<br/>    "requires": "logging_storage",<br/>    "role_assignments": [<br/>      {<br/>        "role_definition_name": "Storage Blob Data Contributor",<br/>        "scope_ref": "logging_storage"<br/>      }<br/>    ],<br/>    "service_account": "loki"<br/>  }<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_mode"></a> [access\_mode](#output\_access\_mode) | Current K8s API access mode |
| <a name="output_api_endpoint_access_type"></a> [api\_endpoint\_access\_type](#output\_api\_endpoint\_access\_type) | Type of access to the K8s API endpoint |
| <a name="output_application_gateway_fqdn"></a> [application\_gateway\_fqdn](#output\_application\_gateway\_fqdn) | FQDN of the Application Gateway public IP (null when appgw\_frontend\_type = "private") |
| <a name="output_application_gateway_id"></a> [application\_gateway\_id](#output\_application\_gateway\_id) | ID of the Application Gateway |
| <a name="output_application_gateway_name"></a> [application\_gateway\_name](#output\_application\_gateway\_name) | Name of the Application Gateway |
| <a name="output_application_gateway_private_ip"></a> [application\_gateway\_private\_ip](#output\_application\_gateway\_private\_ip) | Private frontend IP address of the Application Gateway (null when appgw\_frontend\_type = "public") |
| <a name="output_application_gateway_public_ip"></a> [application\_gateway\_public\_ip](#output\_application\_gateway\_public\_ip) | Public IP address of the Application Gateway (null when appgw\_frontend\_type = "private") |
| <a name="output_cluster_access_mode"></a> [cluster\_access\_mode](#output\_cluster\_access\_mode) | Current cluster API access configuration |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Endpoint/FQDN of the Kubernetes cluster |
| <a name="output_cluster_id"></a> [cluster\_id](#output\_cluster\_id) | ID of the Kubernetes cluster |
| <a name="output_cluster_kube_config_raw"></a> [cluster\_kube\_config\_raw](#output\_cluster\_kube\_config\_raw) | Raw kubeconfig for the Kubernetes cluster |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the Kubernetes cluster |
| <a name="output_cluster_node_resource_group"></a> [cluster\_node\_resource\_group](#output\_cluster\_node\_resource\_group) | Auto-created resource group containing AKS node VMs |
| <a name="output_cluster_subnet_id"></a> [cluster\_subnet\_id](#output\_cluster\_subnet\_id) | ID of the cluster subnet |
| <a name="output_database_address"></a> [database\_address](#output\_database\_address) | Address of the primary (core) database server |
| <a name="output_database_admin_password"></a> [database\_admin\_password](#output\_database\_admin\_password) | Administrator password for the primary (core) database |
| <a name="output_database_admin_passwords"></a> [database\_admin\_passwords](#output\_database\_admin\_passwords) | Administrator password for each named PostgreSQL server |
| <a name="output_database_admin_username"></a> [database\_admin\_username](#output\_database\_admin\_username) | Administrator username for the primary (core) database |
| <a name="output_database_admin_usernames"></a> [database\_admin\_usernames](#output\_database\_admin\_usernames) | Administrator username for each named PostgreSQL server |
| <a name="output_database_endpoint"></a> [database\_endpoint](#output\_database\_endpoint) | FQDN of the primary (core) database server |
| <a name="output_database_endpoints"></a> [database\_endpoints](#output\_database\_endpoints) | FQDN of each named PostgreSQL Flexible Server, keyed by database name |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Name of the primary (core) database |
| <a name="output_database_names"></a> [database\_names](#output\_database\_names) | Initial database name for each named PostgreSQL server |
| <a name="output_database_port"></a> [database\_port](#output\_database\_port) | Port of the database server |
| <a name="output_database_server_name"></a> [database\_server\_name](#output\_database\_server\_name) | Name of the primary (core) database server |
| <a name="output_general_storage_id"></a> [general\_storage\_id](#output\_general\_storage\_id) | ID of the general storage |
| <a name="output_general_storage_name"></a> [general\_storage\_name](#output\_general\_storage\_name) | Name of the general storage |
| <a name="output_general_storage_region"></a> [general\_storage\_region](#output\_general\_storage\_region) | Region of the general storage |
| <a name="output_ingress_subnet_id"></a> [ingress\_subnet\_id](#output\_ingress\_subnet\_id) | ID of the ingress/Application Gateway subnet |
| <a name="output_key_vault_id"></a> [key\_vault\_id](#output\_key\_vault\_id) | ID of the Azure Key Vault |
| <a name="output_key_vault_name"></a> [key\_vault\_name](#output\_key\_vault\_name) | Name of the Azure Key Vault |
| <a name="output_key_vault_uri"></a> [key\_vault\_uri](#output\_key\_vault\_uri) | URI of the Azure Key Vault |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl access |
| <a name="output_logging_storage_id"></a> [logging\_storage\_id](#output\_logging\_storage\_id) | ID of the logging storage |
| <a name="output_logging_storage_name"></a> [logging\_storage\_name](#output\_logging\_storage\_name) | Name of the logging storage |
| <a name="output_logging_storage_region"></a> [logging\_storage\_region](#output\_logging\_storage\_region) | Region of the logging storage |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | ID of the virtual network |
| <a name="output_network_name"></a> [network\_name](#output\_network\_name) | Name of the virtual network |
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | ID of the container registry |
| <a name="output_registry_name"></a> [registry\_name](#output\_registry\_name) | Name of the container registry |
| <a name="output_registry_url"></a> [registry\_url](#output\_registry\_url) | Login server URL for the container registry |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | ID of the main resource group |
| <a name="output_resource_group_location"></a> [resource\_group\_location](#output\_resource\_group\_location) | Location of the main resource group |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the main resource group |
| <a name="output_teleport_agent_status"></a> [teleport\_agent\_status](#output\_teleport\_agent\_status) | Command to check Teleport agent status |
| <a name="output_teleport_db_agent_client_id"></a> [teleport\_db\_agent\_client\_id](#output\_teleport\_db\_agent\_client\_id) | Client ID of managed identity for Teleport database agent |
| <a name="output_tfc_agent_status"></a> [tfc\_agent\_status](#output\_tfc\_agent\_status) | Terraform Cloud Agent deployment status |
| <a name="output_workload_identities"></a> [workload\_identities](#output\_workload\_identities) | Map of configured workload identities keyed by name, each { id, client\_id, principal\_id }. |
<!-- END_TF_DOCS -->