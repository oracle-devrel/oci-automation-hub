# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "id" {
  description = "OCID of the dynamic group."
  value       = oci_identity_dynamic_group.this.id
}

output "name" {
  description = "Dynamic group name."
  value       = oci_identity_dynamic_group.this.name
}

output "description" {
  description = "Dynamic group description."
  value       = oci_identity_dynamic_group.this.description
}

output "matching_rule" {
  description = "Dynamic group matching rule."
  value       = oci_identity_dynamic_group.this.matching_rule
}

output "time_created" {
  description = "Creation timestamp."
  value       = oci_identity_dynamic_group.this.time_created
}

output "state" {
  description = "Current lifecycle state."
  value       = oci_identity_dynamic_group.this.state
}