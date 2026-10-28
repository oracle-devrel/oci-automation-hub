# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

data "oci_identity_domain" "selected" {
  domain_id = var.identity_domain_ocid
}

locals {
  app_resource_name        = lower(replace(replace(var.app_name, " ", "_"), "-", "_"))
  normalized_app_base_url  = trimsuffix(var.app_base_url, "/")
  normalized_domain_url    = trimsuffix(data.oci_identity_domain.selected.url, "/")
  redirect_uri             = "${local.normalized_app_base_url}/auth/callback"
  post_logout_redirect_uri = "${local.normalized_app_base_url}/"
  allow_non_https_urls     = startswith(local.normalized_app_base_url, "http://")
}

resource "oci_identity_domains_app" "this" {
  display_name  = var.app_name
  idcs_endpoint = local.normalized_domain_url
  name          = local.app_resource_name
  description   = "OIDC confidential application for the OCI Agent App Server."
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]

  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  active          = true
  client_type     = "confidential"
  is_oauth_client = true
  login_mechanism = "OIDC"

  allowed_grants            = ["authorization_code", "refresh_token"]
  allow_offline             = true
  all_url_schemes_allowed   = local.allow_non_https_urls
  redirect_uris             = [local.redirect_uri]
  post_logout_redirect_uris = [local.post_logout_redirect_uri]
}
