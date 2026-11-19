# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_core_vcn" "sql" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = var.vcn_name
  dns_label      = var.vcn_dns_label
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "sql" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.sql.id
  display_name   = "Internet gateway-${var.vcn_name}"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.sql.id
  display_name   = "public route table-${var.vcn_name}"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.sql.id
  }
}

resource "oci_core_subnet" "dc" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.sql.id
  cidr_block                 = var.dc_subnet_cidr
  display_name               = "sqlagtest-dc-public-subnet"
  dns_label                  = "dcsubnet"
  route_table_id             = oci_core_route_table.public.id
  dhcp_options_id            = oci_core_vcn.sql.default_dhcp_options_id
  security_list_ids          = [oci_core_security_list.dc.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "sql1" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.sql.id
  cidr_block                 = var.sql1_subnet_cidr
  display_name               = "sqlagtest-sql1-public-subnet"
  dns_label                  = "sql1subnet"
  route_table_id             = oci_core_route_table.public.id
  dhcp_options_id            = oci_core_vcn.sql.default_dhcp_options_id
  security_list_ids          = [oci_core_security_list.sql1.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "sql2" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.sql.id
  cidr_block                 = var.sql2_subnet_cidr
  display_name               = "sqlagtest-sql2-public-subnet"
  dns_label                  = "sql2subnet"
  route_table_id             = oci_core_route_table.public.id
  dhcp_options_id            = oci_core_vcn.sql.default_dhcp_options_id
  security_list_ids          = [oci_core_security_list.sql2.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}
