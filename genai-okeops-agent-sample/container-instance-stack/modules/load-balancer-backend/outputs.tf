# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "backend_id" {
  description = "ID of the load balancer backend."
  value       = oci_load_balancer_backend.this.id
}

output "backend_ip_address" {
  description = "Private IP address registered as a backend."
  value       = oci_load_balancer_backend.this.ip_address
}
