# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "id" {
  description = "OCID of the identity policy."
  value       = oci_identity_policy.this.id
}