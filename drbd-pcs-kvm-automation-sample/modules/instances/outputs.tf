# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  linux_instances = {
    for instance in oci_core_instance.this:
      instance.display_name => { "id" : instance.id, "ip": instance.public_ip != "" ? instance.public_ip : instance.private_ip }
  }
  
  linux_ids = {
    for instance in oci_core_instance.this:
      instance.display_name => instance.id
  }

  linux_private_ips = {
    for instance in oci_core_instance.this:
      instance.display_name => instance.private_ip
  }

  instances_full_details = {
    for instance in oci_core_instance.this:
      instance.display_name => instance
  }
}

output "linux_instances" {
  value = local.linux_instances
}

output "all_instances" {
  value = local.linux_ids
}

output "all_private_ips" {
  value = local.linux_private_ips
}

output "instances_full_details" {
  value = local.instances_full_details
}


output "instance_public_ips" {
  description = "Public IPs of OCI instances"
  value = {
    for name, inst in oci_core_instance.this :
    name => inst.public_ip
    if inst.public_ip != null
  }
}
