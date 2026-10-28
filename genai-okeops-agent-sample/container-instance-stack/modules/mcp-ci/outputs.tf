# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "container_instance_id" {
  description = "OCID of the created container instance."
  value       = oci_container_instances_container_instance.this.id
}

output "container_instance_state" {
  description = "Lifecycle state of the container instance."
  value       = oci_container_instances_container_instance.this.state
}

output "container_instance_display_name" {
  description = "Display name of the container instance."
  value       = oci_container_instances_container_instance.this.display_name
}

output "container_vnic_details" {
  description = "VNIC details for the container instance."
  value       = oci_container_instances_container_instance.this.vnics
}
