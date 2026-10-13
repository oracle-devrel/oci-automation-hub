output "id" {
  description = "OIC instance OCID."
  value       = oci_integration_integration_instance.this.id
}

output "instance_url" {
  description = "OIC instance URL."
  value       = oci_integration_integration_instance.this.instance_url
}

output "idcs_app_id" {
  description = "Identity Domains application ID created for the OIC instance."
  value       = try(oci_integration_integration_instance.this.idcs_info[0].idcs_app_id, null)
}

output "idcs_app_name" {
  description = "Identity Domains application name created for the OIC instance."
  value       = try(oci_integration_integration_instance.this.idcs_info[0].idcs_app_name, null)
}

output "primary_audience_url" {
  description = "Primary audience URL exposed by the OIC-created application."
  value       = try(oci_integration_integration_instance.this.idcs_info[0].instance_primary_audience_url, null)
}
