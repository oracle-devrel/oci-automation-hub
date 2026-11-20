# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "id" {
  description = "Identity Domains application ID."
  value       = oci_identity_domains_app.this.id
}

output "name" {
  description = "Application name."
  value       = oci_identity_domains_app.this.name
}

output "display_name" {
  description = "Application display name."
  value       = oci_identity_domains_app.this.display_name
}

output "client_secret" {
  description = "Generated client secret."
  value       = oci_identity_domains_app.this.client_secret
  sensitive   = true
}
