# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_vcn" "this" {
  compartment_id = var.project_compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name}-vcn"
  dns_label      = "okeopt"
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-nat"
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-sgw"
  freeform_tags  = local.common_tags
  services {
    service_id = data.oci_core_services.all.services[0].id
  }
  vcn_id = oci_core_vcn.this.id
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-public-rt"
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-private-rt"
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

resource "oci_core_security_list" "oke" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-security-list"
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  egress_security_rules {
    destination      = data.oci_core_services.all.services[0].cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    description = "Allow all VCN-internal OKE control plane, node, and pod traffic."
    protocol    = "all"
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.allowed_kubernetes_api_cidrs)
    content {
      description = "Kubernetes API public endpoint access."
      protocol    = "6"
      source      = ingress_security_rules.value
      source_type = "CIDR_BLOCK"

      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }
}

resource "oci_core_security_list" "image_builder" {
  compartment_id = var.project_compartment_ocid
  display_name   = "${var.name}-image-builder-security-list"
  freeform_tags  = local.common_tags
  vcn_id         = oci_core_vcn.this.id

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    description = "SSH access for Terraform image-builder verification."
    protocol    = "6"
    source      = var.image_builder_ssh_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_subnet" "api_endpoint" {
  cidr_block                 = var.api_endpoint_subnet_cidr
  compartment_id             = var.project_compartment_ocid
  display_name               = "${var.name}-api-endpoint"
  dns_label                  = "api"
  freeform_tags              = local.common_tags
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.oke.id]
  vcn_id                     = oci_core_vcn.this.id
}

resource "oci_core_subnet" "workers" {
  cidr_block                 = var.worker_subnet_cidr
  compartment_id             = var.project_compartment_ocid
  display_name               = "${var.name}-workers"
  dns_label                  = "workers"
  freeform_tags              = local.common_tags
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.oke.id]
  vcn_id                     = oci_core_vcn.this.id
}

resource "oci_core_subnet" "pods" {
  cidr_block                 = var.pod_subnet_cidr
  compartment_id             = var.project_compartment_ocid
  display_name               = "${var.name}-pods"
  dns_label                  = "pods"
  freeform_tags              = local.common_tags
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.oke.id]
  vcn_id                     = oci_core_vcn.this.id
}

resource "oci_core_subnet" "load_balancers" {
  cidr_block                 = var.load_balancer_subnet_cidr
  compartment_id             = var.project_compartment_ocid
  display_name               = "${var.name}-load-balancers"
  dns_label                  = "lb"
  freeform_tags              = local.common_tags
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.oke.id]
  vcn_id                     = oci_core_vcn.this.id
}

resource "oci_core_subnet" "image_builder" {
  cidr_block                 = var.image_builder_subnet_cidr
  compartment_id             = var.project_compartment_ocid
  display_name               = "${var.name}-image-builder"
  dns_label                  = "builder"
  freeform_tags              = local.common_tags
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.image_builder.id]
  vcn_id                     = oci_core_vcn.this.id
}
