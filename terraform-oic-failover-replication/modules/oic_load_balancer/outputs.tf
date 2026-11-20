# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "id" {
  description = "OCID of the public regional load balancer."
  value       = oci_load_balancer_load_balancer.this.id
}

output "public_ip_address" {
  description = "Public IPv4 address assigned to the load balancer."
  value = one([
    for address in oci_load_balancer_load_balancer.this.ip_address_details :
    address.ip_address if address.is_public
  ])
}
