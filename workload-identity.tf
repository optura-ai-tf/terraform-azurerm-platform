# Generic Workload Identity map for AKS. See var.workload_identities.
#
# The variable default declares the platform identities (logging, documents,
# documents-processing) with their static config. This file resolves the dynamic
# parts a variable default cannot express:
#   - scope_ref  -> the live target resource ID (local.wi_scope_refs)
#   - the "__foundry_user__" sentinel -> the Foundry User role-definition ID
#   - logging's UAMI/FIC names -> cluster-derived (preserves the existing
#     client_id so gitops SA annotations and cross-repo RBAC keep resolving)
# and gates the builtins on their feature flags by dropping any identity whose
# every declared role resolves to a disabled (null) target.
#
# The resource names are preserved verbatim from the bespoke resources these
# replace, so the migration is moved-only (see azure/moved.tf): 0 add, 0 destroy.

locals {
  # Symbolic scope targets -> live resource IDs. The [0] index is only read when
  # the matching wi_scope_available flag is true (the role is filtered out
  # otherwise), so these never index a count=0 resource.
  #
  # KEEP IN SYNC: the set of valid scope_ref / requires targets is declared in
  # FOUR places — this map, wi_scope_available below, the scope_ref enum
  # validation in variables.tf, and the requires enum validation in variables.tf.
  # Adding a target means editing all four; a key present here but missing from
  # the validation enums would be rejected at plan, and one missing here
  # resolves to a null scope.
  wi_scope_refs = {
    logging_storage = try(azurerm_storage_account.logging[0].id, null)
    general_storage = try(azurerm_storage_account.storage[0].id, null)
    foundry         = try(azurerm_cognitive_account.foundry[0].id, null)
  }

  # Availability of each symbolic target, keyed off the feature FLAG (a value
  # known at plan time). The role-inclusion filter below MUST gate on these
  # booleans, not on whether the resolved scope ID is null: on a greenfield
  # apply the storage account ID is "known after apply" (unknown, not null), and
  # a for_each whose key set depends on an unknown value fails at plan.
  #
  # Each target maps to exactly its own feature flag — they are orthogonal.
  # `foundry` is gated only on foundry_enabled and is freely usable by any
  # workload (storage-bound or not). An identity that must additionally track a
  # different flag (e.g. documents-processing should not exist without storage
  # even though it also holds the flag-independent foundry role) declares it via
  # the per-identity `requires` field; see the identity gate below.
  wi_scope_available = {
    logging_storage = var.storage_logging_enabled
    general_storage = var.storage_general_enabled
    foundry         = var.foundry_enabled
  }

  # Foundry User role, by ID (display name unstable during the
  # "Azure AI User" -> "Foundry User" rename rollout). Built-in GUID is
  # constant across subscriptions/tenants, but the subscription-scoped form is
  # used here because the Azure provider stores role_definition_id in
  # subscription-scoped form in state. Using the unscoped (/providers/...)
  # form would diverge from the state left by the moved-from resources,
  # triggering a ForceNew destroy+create instead of a 0-to-destroy move.
  wi_foundry_user_role_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"

  # Resolve each identity: pin logging's name, map scope_ref -> resource ID,
  # expand the foundry sentinel, and drop role assignments whose symbolic target
  # is disabled by its feature flag. role_assignments becomes a map keyed by the
  # ORIGINAL list index so for_each keys stay stable across foundry on/off
  # (storage stays ":0", foundry stays ":1"). A raw `scope` (operator entries) is
  # always active; a `scope_ref` is active only when wi_scope_available is true.
  wi_resolved = {
    for k, wi in var.workload_identities : k => {
      uami_name = (
        k == "logging"
        ? "${azurerm_kubernetes_cluster.main.name}-logging-identity"
        : coalesce(wi.name, "id-${local.name_prefix}-${k}-identity")
      )
      namespaces      = wi.namespaces
      service_account = wi.service_account
      role_assignments = {
        for idx, ra in coalesce(wi.role_assignments, []) :
        idx => {
          scope                = ra.scope != null ? ra.scope : lookup(local.wi_scope_refs, ra.scope_ref, null)
          role_definition_name = ra.role_definition_name == "__foundry_user__" ? null : ra.role_definition_name
          role_definition_id   = ra.role_definition_name == "__foundry_user__" ? local.wi_foundry_user_role_id : ra.role_definition_id
        }
        if ra.scope != null || (ra.scope_ref != null && lookup(local.wi_scope_available, ra.scope_ref, false))
      }
    }
  }

  # Gate (two predicates, ANDed; both depend only on flags, so the key set is
  # plan-known):
  #   1. `requires` — drop the identity unless its required target's feature flag
  #      is on. This is how documents-processing is kept off a storage-less
  #      cluster even though its (flag-independent) foundry role would otherwise
  #      keep it alive. null `requires` = no flag gate.
  #   2. all-roles-filtered — drop an identity that DECLARED roles but had them
  #      all filtered out by a disabled flag (e.g. logging when
  #      storage_logging_enabled = false). Identities that declared zero roles
  #      are kept (federation-only).
  workload_identities = {
    for k, wi in local.wi_resolved : k => wi
    if(var.workload_identities[k].requires == null || lookup(local.wi_scope_available, var.workload_identities[k].requires, false)) && (length(coalesce(var.workload_identities[k].role_assignments, [])) == 0 || length(wi.role_assignments) > 0)
  }

  # Flatten FICs: one per (identity, namespace). Key "<identity>:<namespace>".
  workload_fics = merge([
    for k, wi in local.workload_identities : {
      for ns in wi.namespaces :
      "${k}:${ns}" => {
        identity        = k
        namespace       = ns
        service_account = wi.service_account
        # logging preserves the legacy FIC name (${cluster}-logging-federated)
        # for its FIRST namespace only, so the pre-existing credential moves
        # rather than recreates. Anchoring on namespaces[0] (not on
        # length == 1) means adding a SECOND logging namespace later does NOT
        # rename the existing one — the new namespace gets the unique
        # namespace-qualified template name, the original keeps the legacy name.
        # (name + subject are ForceNew, so a rename = destroy+recreate.)
        fic_name = (
          k == "logging" && ns == wi.namespaces[0]
          ? "${azurerm_kubernetes_cluster.main.name}-logging-federated"
          : "id-${local.name_prefix}-${ns}-${k}-fic"
        )
      }
    }
  ]...)

  # Flatten role assignments: one per (identity, original-index).
  # Key "<identity>:<index>" — the index is the position in the entry's
  # role_assignments list.
  #
  # CONVENTION: APPEND new role assignments to an entry's list, never insert or
  # prepend. The for_each key is positional, and unlike resources a for_each key
  # change can't be relocated with a `moved` block — inserting at position 0
  # shifts every later role's key, so Terraform destroys+recreates them (a brief
  # re-grant of the same role to the same UAMI; no client_id change, but it
  # breaks the move-only guarantee). Appending only ever adds a new key.
  workload_role_assignments = merge([
    for k, wi in local.workload_identities : {
      for idx, ra in wi.role_assignments :
      "${k}:${idx}" => {
        identity             = k
        scope                = ra.scope
        role_definition_name = ra.role_definition_name
        role_definition_id   = ra.role_definition_id
      }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workload_identities

  name                = each.value.uami_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.region

  tags = merge(local.common_tags, {
    Name    = each.value.uami_name
    Purpose = "Workload Identity"
    Service = each.key
  })
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.workload_fics

  name                      = each.value.fic_name
  user_assigned_identity_id = azurerm_user_assigned_identity.workload[each.value.identity].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "workload" {
  for_each = local.workload_role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  role_definition_id   = each.value.role_definition_id
  principal_id         = azurerm_user_assigned_identity.workload[each.value.identity].principal_id
}
