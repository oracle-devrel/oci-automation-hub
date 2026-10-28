# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "identity_domain_issuer" {
  description = "Identity Domain issuer URL for OCI_IDENTITY_DOMAIN_ISSUER."
  value       = trimsuffix(data.oci_identity_domain.selected.url, "/")
}

output "client_id" {
  description = "Confidential application client ID for OCI_OIDC_CLIENT_ID."
  value       = oci_identity_domains_app.this.name
}

output "client_secret" {
  description = "Confidential application client secret for OCI_OIDC_CLIENT_SECRET."
  value       = oci_identity_domains_app.this.client_secret
  sensitive   = true
}

output "app_id" {
  description = "OCI Identity Domain app resource ID."
  value       = oci_identity_domains_app.this.id
}

output "app_ocid" {
  description = "OCI Identity Domain app OCID, when returned by the provider."
  value       = try(oci_identity_domains_app.this.ocid, "")
}

output "redirect_uri" {
  description = "Redirect URI registered on the confidential application."
  value       = "${trimsuffix(var.app_base_url, "/")}/auth/callback"
}

output "post_logout_redirect_uri" {
  description = "Post-logout redirect URI registered on the confidential application."
  value       = "${trimsuffix(var.app_base_url, "/")}/"
}
