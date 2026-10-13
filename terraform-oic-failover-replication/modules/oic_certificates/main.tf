resource "oci_certificates_management_certificate" "listener" {
  compartment_id = var.compartment_id
  name           = "${var.name_prefix}-listener-cert"
  description    = "TLS certificate imported for the ${var.name_prefix} load balancer listener."

  certificate_config {
    config_type     = "IMPORTED"
    certificate_pem = file(pathexpand(var.ssl_certificate_file_path))
    cert_chain_pem  = file(pathexpand(var.ssl_ca_certificate_file_path))
    private_key_pem = file(pathexpand(var.ssl_private_key_file_path))
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}
