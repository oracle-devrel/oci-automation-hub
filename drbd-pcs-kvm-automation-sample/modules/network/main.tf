# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_providers {
    oci = {
      source  = "hashicorp/oci"
      version = "7.25.0"
    }
  }
}

resource "oci_core_virtual_network" "this" {
  for_each       = var.vcn_params
  cidr_block     = each.value.vcn_cidr
  compartment_id = var.compartment_id
  display_name   = each.value.display_name
  dns_label      = each.value.dns_label
}

resource "oci_core_internet_gateway" "this" {
  for_each       = var.igw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name
}

resource "oci_core_nat_gateway" "this" {
  for_each       = var.ngw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name
}

resource "oci_core_service_gateway" "this" {
  for_each       = var.sgw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id

  services {
    service_id = data.oci_core_services.this.services.0.id
  }

  vcn_id       = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name = each.value.display_name
}

data "oci_core_services" "this" {
  filter {
    name   = "cidr_block"
    values = ["^all-.*-services-in-oracle-services-network$"]
    regex  = true
  }
}

resource "oci_core_route_table" "this" {
  for_each       = var.rt_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name

  dynamic "route_rules" {
    iterator = rr
    for_each = each.value.route_rules
    content {
      destination       = rr.value.destination
      destination_type  = rr.value.use_sgw ? "SERVICE_CIDR_BLOCK" : null
      network_entity_id = rr.value.use_igw ? oci_core_internet_gateway.this[lookup(rr.value, "igw_name", null)].id : rr.value.use_sgw ? oci_core_service_gateway.this[lookup(rr.value, "sgw_name", null)].id : oci_core_nat_gateway.this[lookup(rr.value, "ngw_name", null)].id
    }
  }

  dynamic "route_rules" {
    iterator = drg_rr

    for_each = flatten([for drg in var.drg_attachment_params : [for cidr in drg.cidr_rt :
      {
        "cidr" : cidr,
        "drg_id" : oci_core_drg.this[drg.drg_name].id
      }
      if contains(drg.rt_names, each.value.display_name)
    ]])

    content {
      destination       = drg_rr.value.cidr
      network_entity_id = drg_rr.value.drg_id
    }
  }
}

resource "oci_core_security_list" "this" {
  for_each       = var.sl_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name

  dynamic "egress_security_rules" {
    iterator = egress_rules
    for_each = each.value.egress_rules
    content {
      stateless        = egress_rules.value.stateless
      protocol         = egress_rules.value.protocol
      destination      = egress_rules.value.destination
      destination_type = egress_rules.value.destination_type
    }
  }

  dynamic "ingress_security_rules" {
    iterator = ingress_rules
    for_each = each.value.ingress_rules
    content {
      stateless   = ingress_rules.value.stateless
      protocol    = ingress_rules.value.protocol
      source      = ingress_rules.value.source
      source_type = ingress_rules.value.source_type

      dynamic "tcp_options" {
        iterator = tcp_options
        for_each = (lookup(ingress_rules.value, "tcp_options", null) != null) ? ingress_rules.value.tcp_options : []
        content {
          max = tcp_options.value.max
          min = tcp_options.value.min
        }
      }
      dynamic "udp_options" {
        iterator = udp_options
        for_each = (lookup(ingress_rules.value, "udp_options", null) != null) ? ingress_rules.value.udp_options : []
        content {
          max = udp_options.value.max
          min = udp_options.value.min
        }
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  for_each                   = var.subnet_params
  cidr_block                 = each.value.cidr_block
  display_name               = each.value.display_name
  dns_label                  = each.value.dns_label
  prohibit_public_ip_on_vnic = each.value.is_subnet_private
  compartment_id             = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id                     = oci_core_virtual_network.this[each.value.vcn_name].id
  route_table_id             = oci_core_route_table.this[each.value.rt_name].id
  security_list_ids          = [oci_core_security_list.this[each.value.sl_name].id]
}


resource "oci_core_drg" "this" {
  for_each       = var.drg_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  display_name   = each.value.name
}

resource "oci_core_drg_attachment" "this" {
  for_each = var.drg_attachment_params
  drg_id   = oci_core_drg.this[each.value.drg_name].id
  vcn_id   = oci_core_virtual_network.this[each.value.vcn_name].id
}
