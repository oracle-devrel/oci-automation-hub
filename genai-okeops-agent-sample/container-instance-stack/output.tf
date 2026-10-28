# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "app_url" {
  description = "Application URL configured from the load balancer public IP unless app_base_url is overridden."
  value       = local.effective_app_base_url
}

output "load_balancer_public_ip" {
  description = "Public IP address assigned to the HTTPS load balancer listener."
  value       = module.app_load_balancer.public_ip
}

output "load_balancer_id" {
  description = "OCID of the load balancer."
  value       = module.app_load_balancer.load_balancer_id
}

output "load_balancer_backend_set_name" {
  description = "Name of the load balancer backend set."
  value       = module.app_load_balancer.backend_set_name
}

output "load_balancer_backend_id" {
  description = "ID of the load balancer backend registered for the Container Instance."
  value       = module.app_load_balancer_backend.backend_id
}

output "certificate_id" {
  description = "OCID of the imported OCI Certificates service certificate."
  value       = module.app_certificate.certificate_id
}

output "identity_domain_issuer" {
  description = "Identity Domain issuer URL for OCI_IDENTITY_DOMAIN_ISSUER."
  value       = module.identity_domain_app.identity_domain_issuer
}

output "client_id" {
  description = "Confidential application client ID for OCI_OIDC_CLIENT_ID."
  value       = module.identity_domain_app.client_id
}

output "client_secret" {
  description = "Confidential application client secret for OCI_OIDC_CLIENT_SECRET."
  value       = module.identity_domain_app.client_secret
  sensitive   = true
}

output "app_id" {
  description = "OCI Identity Domain app resource ID."
  value       = module.identity_domain_app.app_id
}

output "app_ocid" {
  description = "OCI Identity Domain app OCID, when returned by the provider."
  value       = module.identity_domain_app.app_ocid
}

output "redirect_uri" {
  description = "Redirect URI registered on the confidential application."
  value       = module.identity_domain_app.redirect_uri
}

output "post_logout_redirect_uri" {
  description = "Post-logout redirect URI registered on the confidential application."
  value       = module.identity_domain_app.post_logout_redirect_uri
}

output "container_instance_id" {
  description = "OCID of the test Container Instance."
  value       = module.test_container_instance.container_instance_id
}

output "container_image" {
  description = "Container image deployed for this test."
  value       = module.test_container_instance.container_image
}

output "container_private_ip" {
  description = "Private IP assigned to the Container Instance VNIC and registered with the load balancer."
  value       = module.test_container_instance.private_ip
}

output "container_public_ip" {
  description = "Public IP assigned to the Container Instance VNIC when assign_public_ip is true."
  value       = module.test_container_instance.public_ip
}
