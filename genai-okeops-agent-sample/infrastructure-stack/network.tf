# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_core_subnet" "oke_endpoint" {
  subnet_id = var.oke_endpoint_subnet_id
}

data "oci_core_subnet" "oke_worker" {
  subnet_id = var.oke_worker_subnet_id
}

data "oci_core_subnet" "mcp" {
  subnet_id = coalesce(var.mcp_subnet_id, var.oke_worker_subnet_id)
}

resource "oci_core_network_security_group" "oke" {
  for_each       = toset(["endpoint", "worker"])
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.display_name_prefix}-oke-${each.key}"
}

locals {
  oke_ingress = merge({
    worker_api              = { group = "endpoint", source = data.oci_core_subnet.oke_worker.cidr_block, protocol = "6", port = 6443 }
    worker_control_plane    = { group = "endpoint", source = data.oci_core_subnet.oke_worker.cidr_block, protocol = "6", port = 12250 }
    mcp_api                 = { group = "endpoint", source = data.oci_core_subnet.mcp.cidr_block, protocol = "6", port = 6443 }
    worker_peers            = { group = "worker", source = data.oci_core_subnet.oke_worker.cidr_block, protocol = "all", port = null }
    control_plane_workers   = { group = "worker", source = data.oci_core_subnet.oke_endpoint.cidr_block, protocol = "6", port = null }
    worker_path_discovery   = { group = "endpoint", source = data.oci_core_subnet.oke_worker.cidr_block, protocol = "1", port = null }
    endpoint_path_discovery = { group = "worker", source = data.oci_core_subnet.oke_endpoint.cidr_block, protocol = "1", port = null }
    }, {
    for cidr in var.kubernetes_api_client_cidrs : "client_${cidr}" => {
      group = "endpoint", source = cidr, protocol = "6", port = 6443
    }
  })
}

resource "oci_core_network_security_group_security_rule" "oke_ingress" {
  for_each                  = local.oke_ingress
  network_security_group_id = oci_core_network_security_group.oke[each.value.group].id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = each.key

  dynamic "tcp_options" {
    for_each = each.value.port == null ? [] : [each.value.port]
    content {
      destination_port_range {
        min = tcp_options.value
        max = tcp_options.value
      }
    }
  }
  dynamic "icmp_options" {
    for_each = each.value.protocol == "1" ? [1] : []
    content {
      type = 3
      code = 4
    }
  }
}

# Matches existing subnet egress: OCI services, DNS, registry pulls and node traffic.
resource "oci_core_network_security_group_security_rule" "oke_egress" {
  for_each                  = oci_core_network_security_group.oke
  network_security_group_id = each.value.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}
