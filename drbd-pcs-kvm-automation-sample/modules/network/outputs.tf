# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "vcns" {
  value = {
    for vcn in oci_core_virtual_network.this :
    vcn.display_name => tomap({
                          "id" = vcn.id
                          "cidr" = vcn.cidr_block})
  }
}

output "subnets" {
  value = {
    for subnet in oci_core_subnet.this :
    subnet.display_name => tomap({
                            "id" = subnet.id
                            "cidr" =  subnet.cidr_block})
  }
}

output "subnets_ids" {
  value = {
    for subnet in oci_core_subnet.this :
    subnet.display_name => subnet.id
  }
}

output "drgs" {
  value = {
    for drg in oci_core_drg.this:
      drg.display_name => drg.id
  }
}
