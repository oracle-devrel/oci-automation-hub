# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_certificates_management_certificate" "this" {
  compartment_id = var.compartment_id
  name           = var.certificate_name
  description    = "Self-signed wildcard TLS certificate for the OCI Agent app load balancer."

  certificate_config {
    config_type     = "IMPORTED"
    certificate_pem = var.certificate_pem
    cert_chain_pem  = var.cert_chain_pem
    private_key_pem = var.private_key_pem
    stage           = "CURRENT"
  }
}
