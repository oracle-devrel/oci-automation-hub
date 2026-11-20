# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# output "vcns" {
#   value = module.network.vcns
# }

# output "subnets" {
#   value = module.network.subnets
# }

output "linux_instances" {
  value = module.compute.linux_instances
}

output "buckets" {
  value = module.object-storage.buckets
}

output "ssh_commands" {
  description = "SSH commands using each VM's public IP, or private IP when no public IP is assigned."
  value = join("\n", [
    for instance in var.instance_params :
    format("ssh -i \"%s\" opc@%s", replace(instance.ssh_private_key, "\\", "/"), module.compute.linux_instances[instance.hostname].ip)
  ])
}
