# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_core_vcn" "benchmark" {
  cidr_block     = var.vcn_cidr
  compartment_id = var.compartment_ocid
  display_name   = "${local.safe_name_prefix}-vcn"
  dns_label      = "flbbench"
}

resource "oci_core_default_security_list" "default" {
  manage_default_resource_id = oci_core_vcn.benchmark.default_security_list_id
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-igw"
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-nat"
}

data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "service_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-sgw"

  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-rt-public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-rt-private"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat.id
  }

  route_rules {
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.service_gateway.id
  }
}

resource "oci_core_subnet" "lb" {
  cidr_block                 = var.lb_subnet_cidr
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.benchmark.id
  display_name               = "${local.safe_name_prefix}-lb-private"
  dns_label                  = "lbpriv"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_default_security_list.default.id]
}

resource "oci_core_subnet" "backend" {
  cidr_block                 = var.backend_subnet_cidr
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.benchmark.id
  display_name               = "${local.safe_name_prefix}-backend-private"
  dns_label                  = "backends"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_default_security_list.default.id]
}

resource "oci_core_subnet" "generator" {
  cidr_block                 = var.generator_subnet_cidr
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.benchmark.id
  display_name               = "${local.safe_name_prefix}-generator-public"
  dns_label                  = "gen"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_default_security_list.default.id]
}

resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-nsg-lb"
}

resource "oci_core_network_security_group" "backend" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-nsg-backends"
}

resource "oci_core_network_security_group" "generator" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.safe_name_prefix}-nsg-generator"
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_443_from_generator" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.generator.id
  stateless                 = var.use_stateless_security_rules

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "generator_egress_443_to_lbs" {
  network_security_group_id = oci_core_network_security_group.generator.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.lb.id
  stateless                 = var.use_stateless_security_rules

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "generator_ingress_ephemeral_from_lbs" {
  count = var.use_stateless_security_rules ? 1 : 0

  network_security_group_id = oci_core_network_security_group.generator.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.lb.id
  stateless                 = true

  tcp_options {
    destination_port_range {
      min = 1024
      max = 65535
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress_ephemeral_to_generator" {
  count = var.use_stateless_security_rules ? 1 : 0

  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.generator.id
  stateless                 = true

  tcp_options {
    destination_port_range {
      min = 1024
      max = 65535
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress_80_to_backends" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.backend.id
  stateless                 = var.use_stateless_security_rules

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_ingress_80_from_lb" {
  network_security_group_id = oci_core_network_security_group.backend.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.lb.id
  stateless                 = var.use_stateless_security_rules

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_ephemeral_from_backends" {
  count = var.use_stateless_security_rules ? 1 : 0

  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.backend.id
  stateless                 = true

  tcp_options {
    destination_port_range {
      min = 1024
      max = 65535
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_egress_ephemeral_to_lbs" {
  count = var.use_stateless_security_rules ? 1 : 0

  network_security_group_id = oci_core_network_security_group.backend.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.lb.id
  stateless                 = true

  tcp_options {
    destination_port_range {
      min = 1024
      max = 65535
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_egress_all" {
  network_security_group_id = oci_core_network_security_group.backend.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "generator_ingress_ssh" {
  count = var.ssh_allowed_cidr == "" ? 0 : 1

  network_security_group_id = oci_core_network_security_group.generator.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = var.ssh_allowed_cidr

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "generator_egress_all" {
  network_security_group_id = oci_core_network_security_group.generator.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}
