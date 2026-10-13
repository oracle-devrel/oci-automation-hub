# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.project_compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.name
  type               = var.cluster_type
  vcn_id             = oci_core_vcn.this.id
  freeform_tags      = local.common_tags

  cluster_pod_network_options {
    cni_type = var.cni_type
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.api_endpoint.id
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = var.cni_type == "FLANNEL_OVERLAY" ? "10.244.0.0/16" : null
      services_cidr = "10.96.0.0/16"
    }

    service_lb_subnet_ids = [oci_core_subnet.load_balancers.id]
  }
}

resource "oci_containerengine_node_pool" "bootstrap" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.project_compartment_ocid
  freeform_tags      = local.common_tags
  kubernetes_version = var.kubernetes_version
  name               = "${var.name}-bootstrap"
  node_shape         = var.bootstrap_node_shape
  ssh_public_key     = local.ssh_public_key

  initial_node_labels {
    key   = "oke-optimization.oracle.com/purpose"
    value = "karpenter-controller"
  }

  node_config_details {
    freeform_tags = local.common_tags
    nsg_ids       = []
    size          = var.bootstrap_node_pool_size

    dynamic "placement_configs" {
      for_each = data.oci_identity_availability_domains.ads.availability_domains
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = oci_core_subnet.workers.id
      }
    }

    dynamic "node_pool_pod_network_option_details" {
      for_each = var.cni_type == "OCI_VCN_IP_NATIVE" ? [1] : []
      content {
        cni_type          = var.cni_type
        max_pods_per_node = 31
        pod_subnet_ids    = [oci_core_subnet.pods.id]
      }
    }
  }

  node_metadata = {
    ssh_authorized_keys = local.ssh_public_key
  }

  node_shape_config {
    memory_in_gbs = var.bootstrap_node_memory_in_gbs
    ocpus         = var.bootstrap_node_ocpus
  }

  node_source_details {
    boot_volume_size_in_gbs = var.worker_boot_volume_size_in_gbs
    image_id                = local.worker_image_id
    source_type             = "IMAGE"
  }
}
