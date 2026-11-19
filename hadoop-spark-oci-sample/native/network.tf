# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Network — only created when var.create_vcn = true
###############################################################################

resource "oci_core_vcn" "this" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr_block]
  display_name   = "${var.resource_prefix}-vcn"
  dns_label      = var.vcn_dns_label
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "igw" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_nat_gateway" "natgw" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-natgw"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_service_gateway" "sgw" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-sgw"

  services {
    service_id = data.oci_core_services.all[0].services[0].id
  }

  freeform_tags = var.freeform_tags
}

data "oci_core_services" "all" {
  count = var.create_vcn ? 1 : 0

  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_route_table" "public" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw[0].id
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_route_table" "private" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-private-rt"

  # Default route via NAT for outbound internet (yum / pip / etc.)
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.natgw[0].id
  }

  # Oracle services (Object Storage etc.) via the Service Gateway
  route_rules {
    destination       = data.oci_core_services.all[0].services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.sgw[0].id
  }

  freeform_tags = var.freeform_tags
}

# BDS needs broad intra-cluster connectivity. We open all traffic inside the
# VCN and the standard egress + ICMP rules. Production deployments should
# tighten these to the documented BDS port matrix.
resource "oci_core_security_list" "private" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-private-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # Intra-VCN — all protocols
  ingress_security_rules {
    source    = var.vcn_cidr_block
    protocol  = "all"
    stateless = false
  }

  # ICMP from the world (path MTU + unreachables)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_security_list" "public" {
  count = var.create_vcn ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.resource_prefix}-public-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6" # TCP
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source    = var.vcn_cidr_block
    protocol  = "all"
    stateless = false
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "private" {
  count = var.create_vcn ? 1 : 0

  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this[0].id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${var.resource_prefix}-private-snet"
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_security_list.private[0].id]
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "public" {
  count = var.create_vcn ? 1 : 0

  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this[0].id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.resource_prefix}-public-snet"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public[0].id
  security_list_ids          = [oci_core_security_list.public[0].id]
  freeform_tags              = var.freeform_tags
}
