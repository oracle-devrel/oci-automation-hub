# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = var.name
  vcn_id             = var.vcn_id
  kubernetes_version = var.kubernetes_version
  type               = "BASIC_CLUSTER"

  endpoint_config {
    subnet_id            = var.endpoint_subnet_id
    nsg_ids              = var.endpoint_nsg_ids
    is_public_ip_enabled = var.public_endpoint
  }

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }
}

resource "oci_containerengine_node_pool" "this" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_ocid
  name               = "${var.name}-workers"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape
  ssh_public_key     = var.ssh_public_key != "" ? var.ssh_public_key : null

  node_config_details {
    size    = var.node_count
    nsg_ids = var.worker_nsg_ids
    placement_configs {
      availability_domain = var.availability_domain
      subnet_id           = var.worker_subnet_id
    }
  }

  node_shape_config {
    ocpus         = 2
    memory_in_gbs = 16
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = var.node_image_id
  }
}
