# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "api_endpoint" {
  description = "Orthanc HTTPS endpoint."
  value       = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc"
}

output "dicomweb_endpoint" {
  description = "DICOMweb service root."
  value       = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc/dicom-web"
}

output "private_orthanc_endpoint" {
  description = "Private Orthanc endpoint reachable from the bastion and connected VCN networks."
  value       = "http://${local.nlb_private_ip}:8080/orthanc"
}

output "fastconnect_private_ingest_endpoint" {
  description = "TLS private DICOMweb/Orthanc endpoint for FastConnect clients; null when disabled."
  value = var.enable_fastconnect ? (
    "https://${local.nlb_private_ip}:8443/orthanc"
  ) : null
}

output "fastconnect_private_ingest_certificate" {
  description = "Self-signed certificate to trust when connecting to the FastConnect private-ingest endpoint."
  value       = var.enable_fastconnect ? tls_self_signed_cert.private_ingest[0].cert_pem : null
}

output "fastconnect_status" {
  description = "FastConnect identifiers and provider/BGP lifecycle; null when disabled."
  value = var.enable_fastconnect ? {
    drg_id             = oci_core_drg.fastconnect[0].id
    drg_attachment_id  = oci_core_drg_attachment.dicom[0].id
    virtual_circuit_id = oci_core_virtual_circuit.dicom[0].id
    lifecycle_state    = oci_core_virtual_circuit.dicom[0].state
    provider_state     = oci_core_virtual_circuit.dicom[0].provider_state
    bgp_session_state  = oci_core_virtual_circuit.dicom[0].bgp_session_state
  } : null
}

output "bastion_public_ip" {
  description = "Public IPv4 address of the operator bastion."
  value       = oci_core_instance.bastion.public_ip
}

output "bastion_private_ip" {
  description = "Private IPv4 address of the operator bastion."
  value       = oci_core_instance.bastion.private_ip
}

output "bastion_ssh_command" {
  description = "SSH command prefix; add -i with the private key matching ssh_public_key_path."
  value       = "ssh opc@${oci_core_instance.bastion.public_ip}"
}

output "orthanc_username" {
  description = "Initial Keycloak user assigned the orthanc-admin role."
  value       = var.orthanc_username
}

output "postgres_username" {
  description = "PostgreSQL administrator username."
  value       = var.postgres_admin_username
}

output "orthanc_password" {
  description = "Generated or supplied initial Keycloak Orthanc administrator password."
  value       = local.orthanc_password
  sensitive   = true
}

output "tenant_authorization" {
  description = "Configured tenant labels, Keycloak roles, and OCI Identity Domains group names."
  value = {
    tenants = {
      for tenant_key, tenant in var.orthanc_tenants : tenant_key => {
        display_name = tenant.display_name
        label        = local.tenant_labels[tenant_key]
        roles = {
          for permission in ["viewer", "uploader", "editor", "admin"] :
          permission => "tenant-${tenant_key}-${permission}"
        }
        sso_groups = local.oci_sso_enabled ? {
          for permission in ["viewer", "uploader", "editor", "admin"] :
          permission => local.tenant_sso_roles["tenant-${tenant_key}-${permission}"]
        } : null
      }
    }
    trusted_classifier_role = "orthanc-admin"
    quarantine_behavior     = "Studies are invisible to tenant roles until a trusted classifier assigns exactly one configured label."
  }
}

output "tenant_test_credentials" {
  description = "Synthetic tenant users used only by the automated tenant-isolation acceptance test."
  value       = local.tenant_test_users
  sensitive   = true
}

output "keycloak_endpoint" {
  description = "Keycloak identity-provider endpoint and administration console root."
  value       = "${local.public_base_url}/keycloak"
}

output "keycloak_oci_broker" {
  description = "Non-secret OCI broker settings reconciled into an existing Keycloak realm after bootstrap."
  value = local.oci_sso_enabled ? {
    enabled       = true
    claim_name    = local.oci_sso_group_claim_name
    default_scope = local.keycloak_realm.identityProviders[0].config.defaultScope
    mappers       = local.keycloak_realm.identityProviderMappers
    } : {
    enabled       = false
    claim_name    = null
    default_scope = null
    mappers       = []
  }
}

output "keycloak_admin_username" {
  description = "Keycloak master-realm bootstrap administrator."
  value       = "keycloak-admin"
}

output "keycloak_admin_password" {
  description = "Generated Keycloak master-realm bootstrap administrator password."
  value       = local.keycloak_admin_password
  sensitive   = true
}

output "keycloak_reconciliation" {
  description = "Desired Keycloak realm state consumed by the idempotent post-deployment reconciler."
  value       = local.keycloak_realm
  sensitive   = true
}

output "oci_sso" {
  description = "Non-secret OCI IAM Identity Domains SSO configuration and role-group mapping."
  value = {
    enabled             = local.oci_sso_enabled
    identity_domain_id  = local.oci_sso_enabled ? data.oci_identity_domain.orthanc_sso[0].id : null
    identity_domain_url = local.oci_sso_domain_url
    discovery_url       = local.oci_sso_enabled ? "${local.oci_sso_domain_url}/.well-known/openid-configuration" : null
    client_id           = local.oci_sso_enabled ? oci_identity_domains_app.orthanc_sso[0].name : null
    callback_url        = local.oci_sso_callback_url
    group_names         = local.oci_sso_roles
    orthanc_login_url   = "${local.public_base_url}/orthanc/ui/app/"
  }
}

output "s3_compatibility_endpoint" {
  description = "OCI Object Storage S3 compatibility endpoint used by Orthanc."
  value       = local.s3_compatibility_endpoint
}

output "storage_identity" {
  description = "Existing OCI IAM user and stack-owned access resources used for S3-compatible Object Storage."
  value = var.create_storage_customer_secret_key ? {
    user_email                       = var.storage_user_email
    user_id                          = local.storage_user_id
    user_managed_by_stack            = false
    group_id                         = oci_identity_group.orthanc[0].id
    customer_secret_key_display_name = oci_identity_customer_secret_key.orthanc[0].display_name
    customer_secret_key_managed      = true
    } : {
    user_email                       = null
    user_id                          = null
    user_managed_by_stack            = false
    group_id                         = null
    customer_secret_key_display_name = null
    customer_secret_key_managed      = false
  }
}

output "storage_credentials" {
  description = "S3-compatible credentials used by Orthanc; consumed only by deployment readiness automation."
  value = {
    access_key = local.storage_access_key
    secret_key = local.storage_secret_key
    managed    = var.create_storage_customer_secret_key
  }
  sensitive = true
}

output "storage_customer_secret_key_capacity" {
  description = "Customer Secret Key slot usage for the selected existing OCI IAM user."
  value = var.create_storage_customer_secret_key ? {
    existing = length(data.oci_identity_customer_secret_keys.storage_user[0].customer_secret_keys)
    maximum  = 2
  } : null
}

output "oke_cluster_id" {
  description = "OKE cluster OCID."
  value       = oci_containerengine_cluster.orthanc.id
}

output "oke_manifest" {
  description = "Rendered sensitive Kubernetes manifest consumed by scripts/deploy-oke.sh."
  value       = local.oke_manifest
  sensitive   = true
}

output "postgres_password" {
  description = "Generated or supplied PostgreSQL administrator password."
  value       = local.postgres_password
  sensitive   = true
}

output "resource_ocids" {
  description = "OCIDs of the deployed resources for inventory and cleanup."
  value = {
    vcn                 = oci_core_vcn.dicom.id
    gateway_subnet      = oci_core_subnet.gateway.id
    management_subnet   = oci_core_subnet.management.id
    application_subnet  = oci_core_subnet.application.id
    oke_api_subnet      = oci_core_subnet.oke_api.id
    oke_nodes_subnet    = oci_core_subnet.oke_nodes.id
    oke_pods_subnet     = oci_core_subnet.oke_pods.id
    database_subnet     = oci_core_subnet.database.id
    bastion             = oci_core_instance.bastion.id
    drg                 = try(oci_core_drg.fastconnect[0].id, null)
    drg_attachment      = try(oci_core_drg_attachment.dicom[0].id, null)
    virtual_circuit     = try(oci_core_virtual_circuit.dicom[0].id, null)
    api_gateway         = oci_apigateway_gateway.orthanc.id
    api_deployment      = oci_apigateway_deployment.orthanc.id
    keycloak_deployment = oci_apigateway_deployment.keycloak.id
    reserved_nlb_ip     = oci_core_private_ip.orthanc_nlb.id
    oke_cluster         = oci_containerengine_cluster.orthanc.id
    oke_node_pool       = oci_containerengine_node_pool.orthanc.id
    postgres            = oci_psql_db_system.orthanc.id
    bucket              = oci_objectstorage_bucket.dicom.id
    log_group           = oci_logging_log_group.dicom.id
    oci_sso_app         = local.oci_sso_enabled ? coalesce(oci_identity_domains_app.orthanc_sso[0].ocid, oci_identity_domains_app.orthanc_sso[0].id) : null
    oci_sso_groups = {
      for role, group in oci_identity_domains_group.orthanc_sso :
      role => coalesce(group.ocid, group.id)
    }
  }
}

output "deployment_summary" {
  description = "Non-secret deployment summary."
  value = {
    name                = local.resource_name
    region              = var.region
    bastion_public_ip   = oci_core_instance.bastion.public_ip
    bastion_ssh_command = "ssh opc@${oci_core_instance.bastion.public_ip}"
    api_endpoint        = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc"
    dicomweb_endpoint   = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc/dicom-web"
    keycloak_endpoint   = "${local.public_base_url}/keycloak"
    oci_sso_enabled     = local.oci_sso_enabled
    oci_sso_domain      = local.oci_sso_domain_url
    oci_sso_groups      = local.oci_sso_roles
    private_endpoint    = "http://${local.nlb_private_ip}:8080/orthanc"
    private_ingest_endpoint = var.enable_fastconnect ? (
      "https://${local.nlb_private_ip}:8443/orthanc"
    ) : null
    bucket_name            = oci_objectstorage_bucket.dicom.name
    namespace              = data.oci_objectstorage_namespace.this.namespace
    s3_endpoint            = local.s3_compatibility_endpoint
    storage_user_email     = var.create_storage_customer_secret_key ? var.storage_user_email : null
    storage_user_managed   = false
    oke_cluster_id         = oci_containerengine_cluster.orthanc.id
    oke_node_pool_id       = oci_containerengine_node_pool.orthanc.id
    oke_kubernetes_version = var.oke_kubernetes_version
    calico_profile         = local.oke_kubernetes_minor
    calico_version         = local.calico_release
    oke_node_image         = local.oke_node_image_name
    bastion_kubectl_arch   = local.bastion_kubectl_arch
    nlb_private_ip         = local.nlb_private_ip
    postgres_private_ip    = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
    orthanc_replicas       = var.orthanc_replicas
    keycloak_replicas      = var.keycloak_replicas
    postgres_nodes = {
      configured  = var.postgres_instances
      provisioned = length(oci_psql_db_system.orthanc.instances)
      active = length([
        for instance in oci_psql_db_system.orthanc.instances : instance
        if instance.state == "ACTIVE"
      ])
      availability_domains = sort(distinct([
        for instance in oci_psql_db_system.orthanc.instances : instance.availability_domain
      ]))
    }
  }
}

output "acceptance_context" {
  description = "Non-secret OCI identifiers and CLI context consumed by acceptance and recovery tests."
  value = {
    auth               = var.oci_auth
    profile            = var.oci_profile
    region             = var.region
    compartment_id     = var.compartment_id
    bucket_name        = oci_objectstorage_bucket.dicom.name
    namespace          = data.oci_objectstorage_namespace.this.namespace
    postgres_id        = oci_psql_db_system.orthanc.id
    postgres_subnet_id = oci_core_subnet.database.id
    postgres_nsg_ids   = [local.postgres_nsg.id]
    postgres_version   = var.postgres_version
    postgres_shape     = var.postgres_shape
  }
}
