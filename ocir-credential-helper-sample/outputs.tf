# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "vcns" {
  value = module.network.vcns
}

output "subnets" {
  value = module.network.subnets
}

output "linux_instances" {
  value = module.compute.linux_instances
}
