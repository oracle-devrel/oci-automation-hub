# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  oci_sso_enabled = var.oci_identity_domain_sso != null
  oci_cli_auth = {
    APIKey              = "api_key"
    SecurityToken       = "security_token"
    InstancePrincipal   = "instance_principal"
    ResourcePrincipal   = "resource_principal"
    OKEWorkloadIdentity = "oke_workload_identity"
  }
  oci_sso_role_labels = local.oci_sso_enabled ? merge(
    var.oci_identity_domain_sso.group_names,
    local.tenant_sso_roles,
  ) : {}
  oci_sso_roles = {
    for role, label in local.oci_sso_role_labels :
    role => "${local.resource_name} - ${label}"
  }
  oci_sso_domain_url = local.oci_sso_enabled ? trimsuffix(
    data.oci_identity_domain.orthanc_sso[0].url,
    "/",
  ) : null
  oci_sso_issuer = local.oci_sso_enabled ? "${trimsuffix(replace(local.oci_sso_domain_url, ":443", ""), "/")}/" : null
  oci_sso_callback_url = local.oci_sso_enabled ? (
    # Keycloak exposes the external OIDC identity-provider callback at the
    # broker endpoint path. OCI Identity Domains requires an exact match.
    "${local.public_base_url}/keycloak/realms/orthanc/broker/oci/endpoint"
  ) : null
  oci_sso_group_claim_name = local.oci_sso_enabled ? "${replace(local.resource_name, "-", "_")}_group_names" : null
  automation_scripts_dir = fileexists("${path.module}/../scripts/manage-oci-custom-claim.sh") ? (
    "${path.module}/../scripts"
  ) : "${path.module}/scripts"
}

data "oci_identity_domain" "orthanc_sso" {
  count    = local.oci_sso_enabled ? 1 : 0
  provider = oci.home

  domain_id = try(var.oci_identity_domain_sso.identity_domain_id, null)
}

resource "oci_identity_domains_app" "orthanc_sso" {
  count    = local.oci_sso_enabled ? 1 : 0
  provider = oci.home

  idcs_endpoint = local.oci_sso_domain_url
  display_name  = "${local.resource_name} Orthanc SSO"
  name          = "${local.resource_name}-orthanc-sso"
  description   = "OIDC client used by the ${local.resource_name} Keycloak broker for Orthanc SSO"
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]

  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  active                  = true
  is_oauth_client         = true
  is_login_target         = true
  client_type             = "confidential"
  login_mechanism         = "OIDC"
  allowed_grants          = ["authorization_code", "refresh_token"]
  allow_offline           = true
  allow_access_control    = true
  bypass_consent          = true
  all_url_schemes_allowed = false
  redirect_uris           = [local.oci_sso_callback_url]
  post_logout_redirect_uris = [
    "${local.public_base_url}/orthanc/ui/app/",
  ]
  logout_uri       = "${local.public_base_url}/orthanc/ui/app/"
  home_page_url    = "${local.public_base_url}/orthanc/ui/app/"
  landing_page_url = "${local.public_base_url}/orthanc/ui/app/"
  force_delete     = true

  # OCI's built-in get_groups claim is an array of objects. Keycloak's stock
  # Claim-to-Role mapper only matches scalar values or arrays of scalars, so
  # expose a stack-specific scope whose custom claim flattens group names.
  is_oauth_resource = true
  audience          = "${local.public_base_url}/orthanc"
  scopes {
    value            = "/group_names"
    display_name     = "Orthanc group names"
    description      = "Group display names used by the Orthanc Keycloak broker"
    requires_consent = false
  }

  lifecycle {
    ignore_changes = [schemas]

    precondition {
      condition = length(distinct([
        for group_name in values(local.oci_sso_role_labels) : lower(trimspace(group_name))
      ])) == length(local.oci_sso_role_labels)
      error_message = "Every OCI Identity Domains group display name must be globally unique across platform and tenant roles."
    }
  }
}

resource "terraform_data" "orthanc_sso_group_claim" {
  for_each = local.oci_sso_enabled ? toset(["enabled"]) : toset([])

  input = {
    endpoint    = local.oci_sso_domain_url
    claim_name  = local.oci_sso_group_claim_name
    scope       = one(oci_identity_domains_app.orthanc_sso[0].scopes).fqs
    profile     = var.oci_profile
    auth        = local.oci_cli_auth[var.oci_auth]
    scripts_dir = local.automation_scripts_dir
  }

  triggers_replace = [
    local.oci_sso_group_claim_name,
    one(oci_identity_domains_app.orthanc_sso[0].scopes).fqs,
    var.oci_profile,
    var.oci_auth,
  ]

  provisioner "local-exec" {
    command = "${local.automation_scripts_dir}/manage-oci-custom-claim.sh ensure"
    environment = {
      OCI_IDENTITY_DOMAIN_URL = self.input.endpoint
      OCI_CUSTOM_CLAIM_NAME   = self.input.claim_name
      OCI_CUSTOM_CLAIM_SCOPE  = self.input.scope
      OCI_CLI_PROFILE         = self.input.profile
      OCI_CLI_AUTH            = self.input.auth
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${self.input.scripts_dir}/manage-oci-custom-claim.sh delete"
    environment = {
      OCI_IDENTITY_DOMAIN_URL = self.input.endpoint
      OCI_CUSTOM_CLAIM_NAME   = self.input.claim_name
      OCI_CUSTOM_CLAIM_SCOPE  = self.input.scope
      OCI_CLI_PROFILE         = self.input.profile
      OCI_CLI_AUTH            = self.input.auth
    }
  }
}

resource "oci_identity_domains_group" "orthanc_sso" {
  for_each = local.oci_sso_roles
  provider = oci.home

  idcs_endpoint = local.oci_sso_domain_url
  display_name  = each.value
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  force_delete  = true

  urnietfparamsscimschemasoracleidcsextensiongroup_group {
    description = "Members receive the ${each.key} role in ${local.resource_name} Orthanc"
  }

  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_grant" "orthanc_sso" {
  for_each = local.oci_sso_roles
  provider = oci.home

  idcs_endpoint   = local.oci_sso_domain_url
  grant_mechanism = "ADMINISTRATOR_TO_GROUP"
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:Grant"]

  grantee {
    type  = "Group"
    value = oci_identity_domains_group.orthanc_sso[each.key].id
  }

  app {
    value = oci_identity_domains_app.orthanc_sso[0].id
  }

  lifecycle {
    ignore_changes = [schemas]
  }
}
