output "certificate_id" {
  description = "OCID of the imported TLS certificate."
  value       = oci_certificates_management_certificate.listener.id
}
