# The provider can't move these to the _v1 types, so they're dropped from state
# and the kubectl_manifest replacements take over the same objects in place.

removed {
  from = kubernetes_namespace.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.tfc_agent_token

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_deployment.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role.teleport_admin

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.teleport_admin

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role.teleport_viewer

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.teleport_viewer

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_config_map.postgresql_ad_setup

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.postgresql_bootstrap_creds

  lifecycle {
    destroy = false
  }
}
