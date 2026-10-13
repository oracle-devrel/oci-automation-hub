terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_identity_domains_app" "this" {
  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  idcs_endpoint = var.idcs_endpoint
  display_name  = var.display_name
  description   = var.description
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]

  active               = var.active
  is_oauth_client      = true
  is_oauth_resource    = false
  client_type          = "confidential"
  allowed_grants       = ["client_credentials"]
  access_token_expiry  = var.access_token_expiry
  refresh_token_expiry = var.refresh_token_expiry
  bypass_consent       = var.bypass_consent
  trust_scope          = var.trust_scope

  dynamic "allowed_scopes" {
    for_each = toset(var.allowed_scope_fqs)

    content {
      fqs = allowed_scopes.value
    }
  }
}
