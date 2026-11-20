# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "application_id" {
  description = "OCID of the OCI Functions application."
  value       = oci_functions_application.this.id
}

output "function_id" {
  description = "OCID of the hourly OIC DR replication function."
  value       = oci_functions_function.this.id
}

output "schedule_id" {
  description = "OCID of the hourly Resource Scheduler schedule."
  value       = oci_resource_scheduler_schedule.this.id
}
