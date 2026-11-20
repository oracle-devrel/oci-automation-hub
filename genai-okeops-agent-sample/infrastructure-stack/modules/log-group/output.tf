# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "id" {
  description = "OCID of the log group."
  value       = oci_logging_log_group.this.id
}

output "display_name" {
  description = "Display name of the log group."
  value       = oci_logging_log_group.this.display_name
}

output "description" {
  description = "Description of the log group."
  value       = oci_logging_log_group.this.description
}

output "compartment_id" {
  description = "OCID of the compartment containing the log group."
  value       = oci_logging_log_group.this.compartment_id
}

output "time_created" {
  description = "Creation timestamp."
  value       = oci_logging_log_group.this.time_created
}

output "state" {
  description = "Current lifecycle state."
  value       = oci_logging_log_group.this.state
}

output "custom_log_id" {
  description = "OCID for the custom log in log group"
  value       = oci_logging_log.devops_custom_logs.id
}