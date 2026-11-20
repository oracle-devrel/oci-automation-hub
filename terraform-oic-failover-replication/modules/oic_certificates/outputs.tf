# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.

output "certificate_id" {
  description = "OCID of the imported TLS certificate."
  value       = oci_certificates_management_certificate.listener.id
}
