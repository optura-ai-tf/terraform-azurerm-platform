# Per-server resolved configuration. Each entry in var.databases
# falls back to the top-level var.postgresql_* defaults when its field is unset,
# guaranteeing that a `{}` entry resolves to the same configuration the legacy
# single-instance server used.
locals {
  databases = var.postgresql_enabled ? var.databases : {}

  # Per-key name suffix used by every supporting resource (UAI, role
  # assignments, K8s ConfigMap/Secret/Job, …). "core" resolves to "" so the
  # legacy unsuffixed names are preserved on upgrade — avoiding ForceNew
  # replacement of resources whose `name` is immutable. Future keys are
  # suffixed unconditionally so they cannot collide with "core".
  db_name_suffix = {
    for k in keys(var.databases) : k => k == "core" ? "" : "-${k}"
  }

  # `coalesce()` (not `try()`) is required here: in Terraform >=1.3 an unset
  # `optional(...)` attribute evaluates to null, not an error. `try()` only
  # catches errors and would propagate the null, leaving required server
  # attributes (sku_name, storage_mb, etc.) unset. `coalesce()` returns the
  # first non-null argument, so the var.* fallback is honoured.
  postgresql_resolved = {
    for k, v in local.databases : k => {
      sku_name                     = coalesce(v.sku_name, var.postgresql_sku_name)
      storage_mb                   = coalesce(v.storage_mb, var.postgresql_storage_mb)
      ha_enabled                   = coalesce(v.ha_enabled, var.postgresql_ha_enabled)
      zone                         = v.zone
      standby_availability_zone    = v.standby_availability_zone
      backup_retention_days        = coalesce(v.backup_retention_days, var.postgresql_backup_retention_days)
      geo_redundant_backup_enabled = coalesce(v.geo_redundant_backup_enabled, false)
      admin_username               = coalesce(v.admin_username, var.postgresql_admin_username)
      db_name                      = coalesce(v.db_name, "${var.project_name}_${var.environment}")
      extensions                   = coalesce(v.extensions, var.postgresql_extensions)
    }
  }
}

# Random password for PostgreSQL admin (per server).
# IMPORTANT: no `keepers` argument — adding a new entry to var.databases
# must NOT rotate the existing core admin password.
resource "random_password" "postgresql_admin" {
  for_each = var.postgresql_enabled ? var.databases : {}
  length   = 24
  special  = true
}

# Private DNS Zone for PostgreSQL (shared across all named servers).
resource "azurerm_private_dns_zone" "postgresql" {
  count               = var.postgresql_enabled ? 1 : 0
  name                = "${var.environment}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# Link Private DNS Zone to VNet (shared across all named servers).
resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  count                 = var.postgresql_enabled ? 1 : 0
  name                  = "postgresql-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgresql[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false

  tags = local.common_tags
}

# Managed Identity for PostgreSQL CMK encryption (one per named server).
resource "azurerm_user_assigned_identity" "postgresql" {
  for_each            = var.enable_cmk && var.postgresql_enabled ? var.databases : {}
  name                = "${local.resource_names.postgresql}${local.db_name_suffix[each.key]}-encryption"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = merge(
    local.common_tags,
    {
      Purpose = "PostgreSQL encryption (${each.key})"
    }
  )
}

# Grant per-server PostgreSQL identity access to Key Vault keys.
resource "azurerm_role_assignment" "kv_crypto_postgresql" {
  for_each             = var.enable_cmk && var.postgresql_enabled ? var.databases : {}
  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.postgresql[each.key].principal_id
}

# PostgreSQL Flexible Server (one per entry in var.databases).
resource "azurerm_postgresql_flexible_server" "main" {
  for_each = var.postgresql_enabled ? var.databases : {}

  # Identifier preservation: "core" keeps the legacy unsuffixed name to avoid
  # destroy+recreate of the existing primary Flexible Server. Every other key
  # is suffixed unconditionally so future names cannot collide.
  name                   = "${local.resource_names.postgresql}${local.db_name_suffix[each.key]}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = var.postgresql_version
  administrator_login    = local.postgresql_resolved[each.key].admin_username
  administrator_password = random_password.postgresql_admin[each.key].result

  # SKU configuration
  sku_name   = local.postgresql_resolved[each.key].sku_name
  storage_mb = local.postgresql_resolved[each.key].storage_mb

  # Initial zone placement. Drift is ignored (lifecycle below) because Azure
  # auto-balances zones; this only honours an explicit `zone` set on the
  # var.databases entry at create time.
  zone = local.postgresql_resolved[each.key].zone

  # Storage configuration with customer-managed key encryption
  auto_grow_enabled = true

  # Customer-managed key encryption
  dynamic "customer_managed_key" {
    for_each = var.enable_cmk ? [1] : []
    content {
      key_vault_key_id                  = azurerm_key_vault_key.postgresql[0].id
      primary_user_assigned_identity_id = azurerm_user_assigned_identity.postgresql[each.key].id
    }
  }

  # Identity for encryption
  dynamic "identity" {
    for_each = var.enable_cmk ? [1] : []
    content {
      type = "UserAssigned"
      identity_ids = [
        azurerm_user_assigned_identity.postgresql[each.key].id
      ]
    }
  }

  # Backup configuration
  backup_retention_days        = local.postgresql_resolved[each.key].backup_retention_days
  geo_redundant_backup_enabled = local.postgresql_resolved[each.key].geo_redundant_backup_enabled

  # High Availability
  dynamic "high_availability" {
    for_each = local.postgresql_resolved[each.key].ha_enabled ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = local.postgresql_resolved[each.key].standby_availability_zone
    }
  }

  # Maintenance window
  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 2
    start_minute = 0
  }

  # VNet integration
  delegated_subnet_id = local.postgresql_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.postgresql[0].id

  # Authentication
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  # No public access
  public_network_access_enabled = false

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone
    ]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgresql,
    azurerm_role_assignment.kv_crypto_postgresql
  ]
}

# Initial database (one per server).
resource "azurerm_postgresql_flexible_server_database" "main" {
  for_each  = var.postgresql_enabled ? var.databases : {}
  name      = local.postgresql_resolved[each.key].db_name
  server_id = azurerm_postgresql_flexible_server.main[each.key].id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Allow-list PostgreSQL extensions required by application services (per server).
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  for_each = var.postgresql_enabled ? var.databases : {}

  server_id = azurerm_postgresql_flexible_server.main[each.key].id
  name      = "azure.extensions"
  value     = join(",", local.postgresql_resolved[each.key].extensions)
}

# ===================================================================
# PostgreSQL Azure AD Authentication Bootstrap (per server)
# ===================================================================
#
# WHY THIS IS NEEDED:
#
# To use Azure AD authentication with PostgreSQL Flexible Server, Azure AD
# users must be created in PostgreSQL using the pgaadauth_create_principal
# function. This is a database-level operation that cannot be set via Azure
# APIs or Terraform's Azure provider.
#
# ===================================================================

# ConfigMap containing SQL script to create Azure AD user (per server).
resource "kubernetes_config_map" "postgresql_ad_setup" {
  for_each = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? var.databases : {}

  metadata {
    name      = "postgresql-ad-setup-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "teleport-agent"
  }

  data = {
    "setup.sql" = <<-SQL
      -- Bind the teleport_admin Postgres principal to the teleport_db_agent
      -- managed identity's Azure AD object ID. Five branches:
      --
      --   Case 1   (clean):           pg_roles has no teleport_admin
      --                               → pgaadauth_create_principal_with_oid
      --   Case 1.5 (orphan non-AAD):  pg_roles has it, pgaadauth doesn't
      --                               (manual CREATE ROLE or prior failed bootstrap)
      --                               → pgaadauth_drop_principal_if_exists + create
      --   Case 2   (no drift):        bound OID matches expected
      --                               → GRANT azure_pg_admin (no-op-ish)
      --   Case 3a  (drift, modern):   bound OID stale, update fn available
      --                               → pgaadauth_update_principal_with_oid (atomic)
      --   Case 3b  (drift, legacy):   bound OID stale, update fn missing
      --                               → drop_principal_if_exists + create (fallback)
      --
      -- Why this matters: when the subscription is moved to a new Azure AD
      -- tenant, the teleport_db_agent MI gets a fresh objectid (AAD identities
      -- are tenant-scoped). The existing teleport_admin PG principal still
      -- binds to the source-tenant OID, so AAD token auth silently fails for
      -- every caller. The previous existence-only check could never recover.
      --
      -- Function signatures (verified on Azure PG Flex 17.x, pgaadauth 1.10):
      --   pgaadauth_list_principals(isadminvalue boolean)
      --     RETURNS TABLE(rolname name, principaltype text, objectid text,
      --                   tenantid text, ismfa integer, isadmin integer)
      --   pgaadauth_create_principal_with_oid(rolename, objectid, objecttype,
      --     isadmin, ismfa) RETURNS text
      --   pgaadauth_update_principal_with_oid(rolename, objectid, objecttype,
      --     isadmin, ismfa) RETURNS text  -- not in MS public docs; gated by EXCEPTION
      --   pgaadauth_drop_principal_if_exists(role_name_to_drop text) RETURNS void

      DO $$
      DECLARE
        expected_oid TEXT := '${azurerm_user_assigned_identity.teleport_db_agent[0].principal_id}';
        current_oid  TEXT;
        role_exists  BOOLEAN;
      BEGIN
        -- Two independent checks: pg_roles for the catalog entry, and
        -- pgaadauth_list_principals for the AAD binding. They can disagree
        -- (orphan non-AAD role) — see Case 1.5 below.
        SELECT EXISTS (
          SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'teleport_admin'
        ) INTO role_exists;

        SELECT objectid INTO current_oid
        FROM pgaadauth_list_principals(true)
        WHERE rolname = 'teleport_admin';

        IF NOT role_exists THEN
          -- Case 1: clean first-time setup
          PERFORM pgaadauth_create_principal_with_oid(
            'teleport_admin', expected_oid, 'service', true, false
          );
          RAISE NOTICE 'Created teleport_admin (OID=%)', expected_oid;

        ELSIF current_oid IS NULL THEN
          -- Case 1.5: pg_roles entry exists but isn't AAD-bound. Could be
          -- a manual CREATE ROLE or a partial prior bootstrap. Replace it.
          PERFORM pgaadauth_drop_principal_if_exists('teleport_admin');
          PERFORM pgaadauth_create_principal_with_oid(
            'teleport_admin', expected_oid, 'service', true, false
          );
          RAISE NOTICE 'Replaced non-AAD teleport_admin with AAD-bound principal (OID=%)', expected_oid;

        ELSIF current_oid <> expected_oid THEN
          -- Case 3: OID drift (tenant transfer). Prefer atomic update; fall
          -- back to drop+create on environments where the update function
          -- isn't exposed (it's not in Microsoft's public pgaadauth docs).
          BEGIN
            PERFORM pgaadauth_update_principal_with_oid(
              'teleport_admin', expected_oid, 'service', true, false
            );
            RAISE NOTICE 'Updated teleport_admin OID: % -> %', current_oid, expected_oid;
          EXCEPTION
            WHEN undefined_function THEN
              PERFORM pgaadauth_drop_principal_if_exists('teleport_admin');
              PERFORM pgaadauth_create_principal_with_oid(
                'teleport_admin', expected_oid, 'service', true, false
              );
              RAISE NOTICE 'Recreated teleport_admin OID: % -> % (update fn unavailable, used drop+create)', current_oid, expected_oid;
          END;

        ELSE
          -- Case 2: OID matches; ensure role membership (cheap, idempotent)
          RAISE NOTICE 'teleport_admin OID unchanged (%)', current_oid;
          GRANT azure_pg_admin TO "teleport_admin";
        END IF;
      END
      $$;

      -- Grant connection privileges to all databases
      GRANT CONNECT ON DATABASE ${azurerm_postgresql_flexible_server_database.main[each.key].name} TO "teleport_admin";
      GRANT CONNECT ON DATABASE postgres TO "teleport_admin";

      -- Grant full privileges on public schema
      GRANT ALL PRIVILEGES ON SCHEMA public TO "teleport_admin";

      -- Grant full table privileges
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "teleport_admin";
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "teleport_admin";
      GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "teleport_admin";

      -- Allow creating new schemas
      GRANT CREATE ON DATABASE ${azurerm_postgresql_flexible_server_database.main[each.key].name} TO "teleport_admin";

      -- Verify the setup
      SELECT
        r.rolname,
        r.rolcanlogin,
        array_agg(m.rolname) AS member_of
      FROM pg_roles r
      LEFT JOIN pg_auth_members am ON r.oid = am.member
      LEFT JOIN pg_roles m ON am.roleid = m.oid
      WHERE r.rolname = 'teleport_admin'
      GROUP BY r.rolname, r.rolcanlogin;
    SQL
  }

  depends_on = [
    azurerm_postgresql_flexible_server.main,
    azurerm_postgresql_flexible_server_database.main,
    helm_release.teleport_kube_agent
  ]
}

# Secret containing database connection info for bootstrap connection (per server).
resource "kubernetes_secret" "postgresql_bootstrap_creds" {
  for_each = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? var.databases : {}

  metadata {
    name      = "postgresql-bootstrap-credentials-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "teleport-agent"
  }

  data = {
    username = azurerm_user_assigned_identity.teleport_db_agent[0].name
    host     = azurerm_postgresql_flexible_server.main[each.key].fqdn
  }

  type = "Opaque"

  depends_on = [
    azurerm_postgresql_flexible_server.main,
    helm_release.teleport_kube_agent
  ]
}

# Replacement trigger for the bootstrap Job. The Job needs to re-run whenever
# the SQL inside `kubernetes_config_map.postgresql_ad_setup` changes — typically
# either an explicit code edit to the SQL string, or an MI principal_id change
# (e.g. tenant transfer) which gets interpolated into the SQL.
#
# A naive approach would be to put a `sha256(...)` annotation onto the Job's
# pod template metadata. That doesn't work: the K8s provider patches that
# in-place rather than recreating the Job, but spec.template is part of the
# immutable JobSpec so K8s silently no-ops the patch — the annotation never
# lands and Terraform re-proposes it on every plan, never actually re-running
# the Job.
#
# Instead, we hash the SQL into a `terraform_data` resource and use
# `lifecycle.replace_triggered_by` on the Job. When the hash changes,
# Terraform performs a full delete + create on the Job, which is exactly
# what we want — fresh pod, fresh SQL execution.
#
# One hash per database key, mirroring the for_each on the ConfigMap and Job.
resource "terraform_data" "postgresql_ad_setup_hash" {
  for_each = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? var.databases : {}

  # Using `triggers_replace` (not `input`) is the canonical pattern for this
  # idiom: when the SHA changes, this resource is itself REPLACED in plan
  # output (-/+), making the cascade to the Job unambiguous. With `input`,
  # the change would render as `~ in-place update`, which still triggers
  # `replace_triggered_by` but reads less clearly in plan diffs.
  triggers_replace = [sha256(kubernetes_config_map.postgresql_ad_setup[each.key].data["setup.sql"])]
}

# Kubernetes Job to create Azure AD user (one per server).
resource "kubernetes_job_v1" "postgresql_ad_bootstrap" {
  for_each = var.access_mode == "teleport" && var.teleport_db_enabled && var.postgresql_enabled ? var.databases : {}

  metadata {
    name      = "postgresql-ad-bootstrap-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "teleport-agent"
  }

  spec {
    template {
      metadata {
        labels = {
          app                           = "postgresql-ad-bootstrap"
          "azure.workload.identity/use" = "true"
        }
      }

      spec {
        restart_policy       = "Never"
        service_account_name = "teleport-kube-agent"

        container {
          name    = "bootstrap"
          image   = "mcr.microsoft.com/azure-cli:latest"
          command = ["/bin/bash"]
          args = [
            "-c",
            <<-SCRIPT
              set -e
              echo "=========================================="
              echo "PostgreSQL Azure AD Authentication Bootstrap (${each.key})"
              echo "=========================================="

              # Install PostgreSQL client (Azure CLI image uses Azure Linux with tdnf)
              echo "Installing PostgreSQL client..."
              tdnf install -y postgresql > /dev/null

              echo "Logging in with Azure Workload Identity..."
              echo "Client ID: $AZURE_CLIENT_ID"
              echo "Tenant ID: $AZURE_TENANT_ID"

              # Login using workload identity (federated token)
              az login --service-principal \
                -u $AZURE_CLIENT_ID \
                -t $AZURE_TENANT_ID \
                --federated-token $(cat $AZURE_FEDERATED_TOKEN_FILE) \
                --allow-no-subscriptions \
                --output none

              if [ $? -ne 0 ]; then
                echo "ERROR: Failed to login with Azure Workload Identity"
                exit 1
              fi

              echo "Successfully logged in!"
              echo "Acquiring Azure AD token for PostgreSQL..."

              export PGPASSWORD=$(az account get-access-token \
                --resource-type oss-rdbms \
                --query accessToken \
                --output tsv)

              if [ -z "$PGPASSWORD" ]; then
                echo "ERROR: Failed to acquire Azure AD token"
                exit 1
              fi

              echo "Token acquired successfully!"
              echo "Waiting for PostgreSQL to accept connections..."

              RETRIES=5
              until psql -h $PGHOST -U $PGUSER -d postgres -c '\q' 2>/dev/null || [ $RETRIES -eq 0 ]; do
                echo "  Attempt $((5 - RETRIES + 1))/5: Waiting..."
                RETRIES=$((RETRIES - 1))
                sleep 5
              done

              if [ $RETRIES -eq 0 ]; then
                echo "ERROR: PostgreSQL did not become ready in time or authentication failed"
                exit 1
              fi

              echo "PostgreSQL is ready!"
              echo "Connecting as Azure AD admin: $PGUSER"
              echo "Creating teleport_admin user..."

              psql -f /scripts/setup.sql

              echo "=========================================="
              echo "Bootstrap completed successfully!"
              echo "=========================================="
            SCRIPT
          ]

          env {
            name = "PGHOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgresql_bootstrap_creds[each.key].metadata[0].name
                key  = "host"
              }
            }
          }

          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgresql_bootstrap_creds[each.key].metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            name  = "PGDATABASE"
            value = "postgres"
          }

          env {
            name  = "PGSSLMODE"
            value = "require"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map.postgresql_ad_setup[each.key].metadata[0].name
          }
        }

        # Schedule on system nodes
        node_selector = {
          "workload-type" = "system"
        }

        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      }
    }

    backoff_limit = 3
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_postgresql_flexible_server.main,
    azurerm_postgresql_flexible_server_database.main,
    kubernetes_config_map.postgresql_ad_setup,
    kubernetes_secret.postgresql_bootstrap_creds,
    azurerm_postgresql_flexible_server_active_directory_administrator.teleport,
    helm_release.teleport_kube_agent
  ]

  # Re-run the Job whenever the SQL hash changes. See `terraform_data.postgresql_ad_setup_hash`
  # above for the rationale (in-place annotation patches don't trigger Job re-execution
  # because spec.template is immutable in K8s; full replace is required).
  lifecycle {
    replace_triggered_by = [
      terraform_data.postgresql_ad_setup_hash[each.key]
    ]
  }
}
