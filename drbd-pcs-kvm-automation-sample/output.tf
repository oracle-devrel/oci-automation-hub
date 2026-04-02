# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "instance_public_ips" {
  description = "Public IPs of OCI instances"
  value = [ module.instances_region1.instance_public_ips, module.instances_region2.instance_public_ips]
}

output "instance_private_ips" {
  description = "Private IPs of OCI instances"
  value = [ module.instances_region1.all_private_ips , module.instances_region2.all_private_ips]
}

output "ssh_public_key" {
  description = "Public SSH key for the stack"
  value       = tls_private_key.stack_key.public_key_openssh
  sensitive   = false
}

# output "ssh_private_key" {
#   description = "Private SSH key for the stack (stored in terraform.tfstate)"
#   value       = tls_private_key.stack_key.private_key_openssh
#   sensitive   = true
# }