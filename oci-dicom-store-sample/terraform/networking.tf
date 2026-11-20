# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_vcn" "dicom" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.resource_name}-vcn"
  dns_label      = "dicom${substr(local.suffix, 0, 6)}"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-internet"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-nat"
  freeform_tags  = local.tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-services"
  freeform_tags  = local.tags

  services {
    service_id = local.all_service_id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-public-routes"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_drg.fastconnect[0].id
    }
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-private-routes"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_drg.fastconnect[0].id
    }
  }
}

resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-nsg-only"
  freeform_tags  = local.tags
}

resource "oci_core_subnet" "gateway" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.gateway_subnet_cidr
  display_name               = "${local.resource_name}-gateway"
  dns_label                  = "gateway"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "management" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.management_subnet_cidr
  display_name               = "${local.resource_name}-management"
  dns_label                  = "management"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "application" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.application_subnet_cidr
  display_name               = "${local.resource_name}-nlb"
  dns_label                  = "nlb"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_private_ip" "orthanc_nlb" {
  subnet_id     = oci_core_subnet.application.id
  ip_address    = cidrhost(var.application_subnet_cidr, 10)
  display_name  = "${local.resource_name}-nlb"
  lifetime      = "RESERVED"
  freeform_tags = local.tags

  lifecycle {
    # OKE assigns the reserved address to the NLB VNIC and renames it. Reverting
    # either service-managed value would interrupt or be rejected by the NLB VNIC.
    ignore_changes = [vnic_id, display_name]
  }
}

resource "oci_core_subnet" "oke_api" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.oke_api_subnet_cidr
  display_name               = "${local.resource_name}-oke-api"
  dns_label                  = "okeapi"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "oke_nodes" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.oke_nodes_subnet_cidr
  display_name               = "${local.resource_name}-oke-nodes"
  dns_label                  = "okenodes"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "oke_pods" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.oke_pods_subnet_cidr
  display_name               = "${local.resource_name}-oke-pods"
  dns_label                  = "okepods"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "database" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.database_subnet_cidr
  display_name               = "${local.resource_name}-database"
  dns_label                  = "db"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

locals {
  network_security_groups = toset([
    "gateway",
    "nlb",
    "oke-api",
    "oke-nodes",
    "oke-pods",
    "postgres",
    "bastion",
  ])
}

resource "oci_core_network_security_group" "this" {
  for_each = local.network_security_groups

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-${each.value}"
  freeform_tags  = local.tags
}

locals {
  gateway_nsg   = oci_core_network_security_group.this["gateway"]
  nlb_nsg       = oci_core_network_security_group.this["nlb"]
  oke_api_nsg   = oci_core_network_security_group.this["oke-api"]
  oke_nodes_nsg = oci_core_network_security_group.this["oke-nodes"]
  oke_pods_nsg  = oci_core_network_security_group.this["oke-pods"]
  postgres_nsg  = oci_core_network_security_group.this["postgres"]
  bastion_nsg   = oci_core_network_security_group.this["bastion"]
}

resource "oci_core_network_security_group_security_rule" "bastion_ssh_ingress" {
  for_each = toset(local.bastion_ssh_cidrs)

  network_security_group_id = local.bastion_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Approved SSH administrators"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "gateway_https_ingress" {
  for_each = toset(var.allowed_client_cidrs)

  network_security_group_id = local.gateway_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Approved Orthanc and Keycloak clients"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "gateway_to_nlb" {
  network_security_group_id = local.gateway_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.nlb_nsg.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "API Gateway to the private OKE NLB"

  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_http_ingress" {
  for_each = {
    gateway = local.gateway_nsg.id
    bastion = local.bastion_nsg.id
  }

  network_security_group_id = local.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "${each.key} to the private Orthanc gateway"

  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_fastconnect_ingress" {
  for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

  network_security_group_id = local.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "FastConnect TLS Orthanc ingest"

  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_to_nodes" {
  for_each = {
    http   = 30080
    https  = 30443
    health = 10256
  }

  network_security_group_id = local.nlb_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.oke_nodes_nsg.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "OKE NLB ${each.key} traffic to worker nodes"

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_from_nlb" {
  for_each = {
    http   = 30080
    https  = 30443
    health = 10256
  }

  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.nlb_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OKE NLB ${each.key} traffic"

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

# OCI Network Load Balancer is a pass-through service and preserves the client
# source address. These rules therefore admit the actual gateway/bastion source
# subnets on the fixed NodePorts instead of relying only on an NLB-NSG source.
resource "oci_core_network_security_group_security_rule" "nodes_http_sources" {
  for_each = {
    gateway = var.gateway_subnet_cidr
    bastion = var.management_subnet_cidr
  }

  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Private NLB HTTP traffic preserving ${each.key} source addresses"

  tcp_options {
    destination_port_range {
      min = 30080
      max = 30080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_fastconnect_sources" {
  for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Private NLB TLS traffic preserving FastConnect source addresses"

  tcp_options {
    destination_port_range {
      min = 30443
      max = 30443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_tls_from_bastion" {
  count = var.enable_fastconnect ? 1 : 0

  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.management_subnet_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Bastion validation of the private TLS listener"

  tcp_options {
    destination_port_range {
      min = 30443
      max = 30443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_ingress" {
  for_each = {
    bastion = local.bastion_nsg.id
    nodes   = local.oke_nodes_nsg.id
    pods    = local.oke_pods_nsg.id
  }

  network_security_group_id = local.oke_api_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Kubernetes API from ${each.key}"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_proxymux" {
  for_each = {
    nodes = local.oke_nodes_nsg.id
    pods  = local.oke_pods_nsg.id
  }

  network_security_group_id = local.oke_api_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OKE control-plane proxymux from ${each.key}"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_egress" {
  network_security_group_id = local.oke_api_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "nodes_internal" {
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.oke_nodes_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"
}

resource "oci_core_network_security_group_security_rule" "nodes_from_api" {
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.oke_api_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_from_pods" {
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.oke_pods_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"
}

resource "oci_core_network_security_group_security_rule" "nodes_ssh" {
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.bastion_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_egress" {
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "pods_ingress" {
  for_each = {
    pods  = local.oke_pods_nsg.id
    nodes = local.oke_nodes_nsg.id
    api   = local.oke_api_nsg.id
  }

  network_security_group_id = local.oke_pods_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = each.value
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Pod traffic from ${each.key}"
}

resource "oci_core_network_security_group_security_rule" "pods_egress" {
  network_security_group_id = local.oke_pods_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "postgres_ingress" {
  for_each = {
    pods    = local.oke_pods_nsg.id
    bastion = local.bastion_nsg.id
  }

  network_security_group_id = local.postgres_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "PostgreSQL from ${each.key}"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_private_egress" {
  for_each = {
    nlb-http = {
      nsg  = local.nlb_nsg.id
      port = 8080
    }
    nlb-tls = {
      nsg  = local.nlb_nsg.id
      port = 8443
    }
    oke-api = {
      nsg  = local.oke_api_nsg.id
      port = 6443
    }
    postgres = {
      nsg  = local.postgres_nsg.id
      port = 5432
    }
  }

  network_security_group_id = local.bastion_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = each.value.nsg
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion ${each.key} access"

  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_https_egress" {
  network_security_group_id = local.bastion_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "OS packages, Kubernetes binaries, and OCI services"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_metadata_egress" {
  network_security_group_id = local.bastion_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  description               = "OCI instance metadata service"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_ntp_egress" {
  network_security_group_id = local.bastion_nsg.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"

  udp_options {
    destination_port_range {
      min = 123
      max = 123
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_dns_egress" {
  for_each = {
    tcp = "6"
    udp = "17"
  }

  network_security_group_id = local.bastion_nsg.id
  direction                 = "EGRESS"
  protocol                  = each.value
  destination               = var.vcn_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "VCN DNS"

  dynamic "tcp_options" {
    for_each = each.key == "tcp" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.key == "udp" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }
}
