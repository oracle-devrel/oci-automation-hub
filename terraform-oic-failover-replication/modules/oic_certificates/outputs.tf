# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "certificate_id" {
  description = "OCID of the imported TLS certificate."
  value       = oci_certificates_management_certificate.listener.id
}
