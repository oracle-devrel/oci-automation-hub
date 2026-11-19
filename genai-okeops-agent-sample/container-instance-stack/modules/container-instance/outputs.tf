# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "container_instance_id" {
  description = "OCID of the Container Instance."
  value       = oci_container_instances_container_instance.app.id
}

output "container_image" {
  description = "Container image deployed by the module."
  value       = var.image_url
}

output "app_url" {
  description = "Application URL configured in APP_BASE_URL."
  value       = trimsuffix(var.app_base_url, "/")
}

output "oidc_redirect_uri" {
  description = "Redirect URI to register in OCI Identity Domain."
  value       = "${trimsuffix(var.app_base_url, "/")}/auth/callback"
}

output "private_ip" {
  description = "Private IP assigned to the Container Instance VNIC."
  value       = data.oci_core_vnic.app.private_ip_address
}

output "public_ip" {
  description = "Public IP assigned to the Container Instance VNIC."
  value       = data.oci_core_vnic.app.public_ip_address
}
