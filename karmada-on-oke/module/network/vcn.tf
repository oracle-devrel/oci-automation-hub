# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_vcn" "oke-vcn" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = var.cidr_blocks
  display_name   = var.vcn_display_name
  dns_label      = "oke"
}

resource "oci_core_subnet" "api_endpoint_subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id
  cidr_block     = var.api_endpoint_subnet_cidr

  display_name = "api_endpoint_subnet"

  route_table_id = oci_core_route_table.oke_public_route_table.id
  dns_label      = "api"
}

resource "oci_core_subnet" "lb_subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id
  cidr_block     = var.lb_subnet_cidr

  display_name = "lb_subnet"

  route_table_id = oci_core_route_table.oke_public_route_table.id
  dns_label      = "lb"
}

resource "oci_core_subnet" "node_pool_subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id
  cidr_block     = var.nodepool_subnet_cidr

  display_name              = "nodepool_subnet`"
  prohibit_internet_ingress = true
  route_table_id            = oci_core_route_table.oke_private_route_table.id
  dns_label                 = "nodepool"
}

resource "oci_core_subnet" "pods_subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id
  cidr_block     = var.pods_subnet_cidr

  display_name              = "pods_subnet`"
  prohibit_internet_ingress = true
  route_table_id            = oci_core_route_table.oke_private_route_table.id
  dns_label                 = "pods"
}

### gateways
resource "oci_core_internet_gateway" "oke_internet_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "oke_internet_gateway"
}

resource "oci_core_nat_gateway" "oke_nat_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "oke_nat_gateway"
}

resource "oci_core_service_gateway" "oke_service_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id
  services {
    service_id = data.oci_core_services.test_services.services[0]["id"]
  }

  display_name = "oke_service_gateway"
}

data "oci_core_services" "test_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}


resource "oci_core_route_table" "oke_public_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "oke_public_route_table"

  route_rules {
    network_entity_id = oci_core_internet_gateway.oke_internet_gateway.id
    destination_type  = "CIDR_BLOCK"
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_route_table" "oke_private_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oke-vcn.id

  display_name = "oke_private_route_table"

  route_rules {
    network_entity_id = oci_core_nat_gateway.oke_nat_gateway.id
    destination_type  = "CIDR_BLOCK"
    destination       = "0.0.0.0/0"
  }

  route_rules {
    network_entity_id = oci_core_service_gateway.oke_service_gateway.id
    destination_type  = "SERVICE_CIDR_BLOCK"
    destination       = data.oci_core_services.test_services.services[0]["cidr_block"]
  }
}