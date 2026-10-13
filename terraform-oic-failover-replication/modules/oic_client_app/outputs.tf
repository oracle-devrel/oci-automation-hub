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
