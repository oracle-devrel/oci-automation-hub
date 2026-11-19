# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Networking
#
#  VCN
#   |- Internet Gateway  -> Kubernetes API endpoint subnet (when public)
#   |- NAT Gateway       -> egress for private worker nodes
#   |- Service Gateway   -> OCI services (OKE control plane, OCIR, Object Storage)
#   |- endpoint subnet   -> the Kubernetes API endpoint
#   |- nodes subnet      -> worker nodes (always private, no public IPs)
#
# Worker nodes never have public IPs. The API endpoint is public-but-NSG-locked
# to admin_cidr by default (so Terraform can deploy the workload layer in one
# run); set cluster_endpoint_is_public = false for a fully private endpoint.
###############################################################################

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.cluster_name}-vcn"
  dns_label      = substr(replace(var.cluster_name, "-", ""), 0, 15)
  freeform_tags  = local.freeform_tags

  lifecycle {
    precondition {
      condition     = var.deploy_hdfs || var.deploy_object_storage || var.deploy_spark
      error_message = "Select at least one component to deploy: deploy_hdfs, deploy_object_storage, and/or deploy_spark."
    }
  }
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-igw"
  enabled        = true
  freeform_tags  = local.freeform_tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-natgw"
  freeform_tags  = local.freeform_tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-sgw"
  freeform_tags  = local.freeform_tags

  services {
    service_id = local.service_id
  }
}

# --------------------------------------------------------------------------
# Route tables
# --------------------------------------------------------------------------
resource "oci_core_route_table" "endpoint" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-endpoint-rt"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = var.cluster_endpoint_is_public ? oci_core_internet_gateway.this.id : oci_core_nat_gateway.this.id
  }
  route_rules {
    destination       = local.service_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

resource "oci_core_route_table" "nodes" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-nodes-rt"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }
  route_rules {
    destination       = local.service_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

# --------------------------------------------------------------------------
# Subnets
# --------------------------------------------------------------------------
resource "oci_core_subnet" "endpoint" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.endpoint_subnet_cidr
  display_name               = "${var.cluster_name}-endpoint-subnet"
  dns_label                  = "endpoint"
  route_table_id             = oci_core_route_table.endpoint.id
  prohibit_public_ip_on_vnic = !var.cluster_endpoint_is_public
  freeform_tags              = local.freeform_tags
}

resource "oci_core_subnet" "nodes" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.nodes_subnet_cidr
  display_name               = "${var.cluster_name}-nodes-subnet"
  dns_label                  = "nodes"
  route_table_id             = oci_core_route_table.nodes.id
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.freeform_tags
}

# Dedicated, private subnet for service load balancers. OKE requires a service
# LB subnet on the cluster, and it must be distinct from the node-pool subnet.
# Kept private (no public IPs); this stack creates no LoadBalancer Services.
resource "oci_core_subnet" "int_lb" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.lb_subnet_cidr
  display_name               = "${var.cluster_name}-int-lb-subnet"
  dns_label                  = "intlb"
  route_table_id             = oci_core_route_table.nodes.id
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.freeform_tags
}

# --------------------------------------------------------------------------
# Network Security Groups
# --------------------------------------------------------------------------
resource "oci_core_network_security_group" "endpoint" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-endpoint-nsg"
  freeform_tags  = local.freeform_tags
}

resource "oci_core_network_security_group" "nodes" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-nodes-nsg"
  freeform_tags  = local.freeform_tags
}

# ---- API endpoint NSG ----------------------------------------------------
# kubectl in, from admin_cidr only.
resource "oci_core_network_security_group_security_rule" "endpoint_in_kubectl" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.admin_cidr
  source_type               = "CIDR_BLOCK"
  description               = "kubectl / API access from admin_cidr"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# Worker nodes -> API endpoint.
resource "oci_core_network_security_group_security_rule" "endpoint_in_nodes_6443" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker nodes to Kubernetes API"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "endpoint_in_nodes_12250" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker nodes control-plane channel"
  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "endpoint_in_icmp" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Path-MTU discovery from worker nodes"
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "endpoint_out_nodes" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "API endpoint to worker nodes (kubelet, etc.)"
}

resource "oci_core_network_security_group_security_rule" "endpoint_out_icmp" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Path-MTU discovery to worker nodes"
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "endpoint_out_osn" {
  network_security_group_id = oci_core_network_security_group.endpoint.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.service_cidr
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "API endpoint to OCI services"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# ---- Worker nodes NSG ----------------------------------------------------
resource "oci_core_network_security_group_security_rule" "nodes_in_self" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Node-to-node and pod-to-pod traffic"
}

resource "oci_core_network_security_group_security_rule" "nodes_in_endpoint" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.endpoint.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "API endpoint to worker nodes (kubelet 10250, etc.)"
}

resource "oci_core_network_security_group_security_rule" "nodes_in_endpoint_icmp" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.endpoint.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Path-MTU discovery from API endpoint"
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_in_ssh" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "SSH from inside the VCN (OCI Bastion)"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_out_all" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Worker node egress (NAT for internet, Service Gateway for OCI services)"
}
