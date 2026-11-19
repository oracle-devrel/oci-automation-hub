# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  home_regions = [
    for subscription in data.oci_identity_region_subscriptions.tenancy.region_subscriptions :
    subscription.region_name if subscription.is_home_region
  ]
  home_region           = one(local.home_regions)
  selected_vcn_id       = var.use_existing_network ? var.existing_vcn_id : oci_core_vcn.app[0].id
  selected_subnet_id    = var.use_existing_network ? var.existing_subnet_id : oci_core_subnet.public[0].id
  selected_network_mode = var.use_existing_network ? "existing" : "created"
}

resource "terraform_data" "network_inputs" {
  input = {
    use_existing_network = var.use_existing_network
    existing_vcn_id      = var.existing_vcn_id
    existing_subnet_id   = var.existing_subnet_id
    new_vcn_cidr         = var.new_vcn_cidr
    new_subnet_cidr      = var.new_subnet_cidr
  }

  lifecycle {
    precondition {
      condition = var.use_existing_network ? (
        trimspace(var.existing_network_compartment_ocid) != "" &&
        trimspace(var.existing_vcn_id) != "" &&
        trimspace(var.existing_subnet_id) != ""
        ) : (
        can(cidrnetmask(var.new_vcn_cidr)) &&
        can(cidrnetmask(var.new_subnet_cidr))
      )
      error_message = "Select an existing VCN and public subnet, or supply valid CIDRs for the new VCN and subnet."
    }
  }
}

resource "oci_core_vcn" "app" {
  count = var.use_existing_network ? 0 : 1

  compartment_id = oci_identity_compartment.application_layers["network"].id
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "${var.name_prefix}vcn"
  cidr_blocks    = [var.new_vcn_cidr]
  freeform_tags  = var.freeform_tags

  depends_on = [terraform_data.network_inputs]
}

resource "oci_core_internet_gateway" "app" {
  count = var.use_existing_network ? 0 : 1

  compartment_id = oci_identity_compartment.application_layers["network"].id
  vcn_id         = oci_core_vcn.app[0].id
  display_name   = "${var.name_prefix}-internet-gateway"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  count = var.use_existing_network ? 0 : 1

  compartment_id = oci_identity_compartment.application_layers["network"].id
  vcn_id         = oci_core_vcn.app[0].id
  display_name   = "${var.name_prefix}-public-routes"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.app[0].id
  }
}

resource "oci_core_subnet" "public" {
  count = var.use_existing_network ? 0 : 1

  compartment_id = oci_identity_compartment.application_layers["network"].id
  vcn_id         = oci_core_vcn.app[0].id
  display_name   = "${var.name_prefix}-public-subnet"
  dns_label      = "app"
  cidr_block     = var.new_subnet_cidr
  route_table_id = oci_core_route_table.public[0].id

  # The browser application is intentionally public. Workloads that require a
  # private subnet need a load balancer/NAT design outside this demo stack.
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags

  depends_on = [terraform_data.network_inputs]
}

# A dedicated NSG is attached to the application VNIC in both modes. Existing
# subnet security lists are not edited by this stack.
resource "oci_core_network_security_group" "app" {
  compartment_id = oci_identity_compartment.application_layers["network"].id
  vcn_id         = local.selected_vcn_id
  display_name   = "${var.name_prefix}-app-nsg"
  freeform_tags  = var.freeform_tags

  depends_on = [terraform_data.network_inputs]
}

resource "oci_core_network_security_group_security_rule" "http_ingress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ssh_ingress" {
  count = var.ssh_public_key == "" ? 0 : 1

  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
