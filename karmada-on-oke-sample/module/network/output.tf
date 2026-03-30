# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "vcn_id" {
    value = oci_core_vcn.oke-vcn.id
  
}

output "api_endpoint_subnet_id" {
    value = oci_core_subnet.api_endpoint_subnet.id
  
}

output "api_endpoint_nsg_ids" {
    value = [oci_core_network_security_group.api_endpoint_nsg.id]
  
}

output "service_lb_subnet_ids" {
    value = [oci_core_subnet.lb_subnet.id]
  
}

output "node_pool_subnet_id" {
    value = oci_core_subnet.node_pool_subnet.id
  
}

output "nodepool_nsg_ids" {
    value = [oci_core_network_security_group.nodepool_nsg.id]
  
}

output "services" {
  value = [data.oci_core_services.test_services.services]
}