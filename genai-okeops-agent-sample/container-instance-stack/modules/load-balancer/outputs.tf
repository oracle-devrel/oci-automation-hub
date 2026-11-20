# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "load_balancer_id" {
  description = "OCID of the load balancer."
  value       = oci_load_balancer_load_balancer.this.id
}

output "load_balancer_name" {
  description = "Display name of the load balancer."
  value       = oci_load_balancer_load_balancer.this.display_name
}

output "public_ip" {
  description = "Public IP address assigned to the load balancer."
  value       = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address
}

output "backend_set_name" {
  description = "Name of the load balancer backend set."
  value       = oci_load_balancer_backend_set.this.name
}

output "listener_name" {
  description = "Name of the HTTPS listener."
  value       = oci_load_balancer_listener.https.name
}
