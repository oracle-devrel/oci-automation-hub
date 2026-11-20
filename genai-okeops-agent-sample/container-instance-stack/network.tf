# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_core_subnet" "lb_network" {
  subnet_id = var.lb_subnet_id
}

data "oci_core_subnet" "app_network" {
  subnet_id = var.app_subnet_id
}

resource "oci_core_network_security_group" "app" {
  for_each       = toset(["lb", "ui", "mcp"])
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_subnet.app_network.vcn_id
  display_name   = "${var.app_name_prefix}-${each.key}"

  lifecycle {
    precondition {
      condition     = data.oci_core_subnet.lb_network.vcn_id == data.oci_core_subnet.app_network.vcn_id
      error_message = "The load balancer and application subnets must belong to the same VCN."
    }
  }
}

locals {
  app_ingress = merge({
    lb_to_ui  = { group = "ui", source = oci_core_network_security_group.app["lb"].id, source_type = "NETWORK_SECURITY_GROUP", port = local.app_port }
    ui_to_mcp = { group = "mcp", source = oci_core_network_security_group.app["ui"].id, source_type = "NETWORK_SECURITY_GROUP", port = 8080 }
    }, {
    for cidr in var.app_client_cidrs : "https_${cidr}" => {
      group = "lb", source = cidr, source_type = "CIDR_BLOCK", port = 443
    }
  })
}

resource "oci_core_network_security_group_security_rule" "app_ingress" {
  for_each                  = local.app_ingress
  network_security_group_id = oci_core_network_security_group.app[each.value.group].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value.source
  source_type               = each.value.source_type
  stateless                 = false
  description               = each.key
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

# OCI APIs, authentication, DNS and private-registry access through existing routes.
resource "oci_core_network_security_group_security_rule" "app_egress" {
  for_each                  = oci_core_network_security_group.app
  network_security_group_id = each.value.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}
