# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_containerengine_cluster" "orthanc" {
  compartment_id     = var.compartment_id
  kubernetes_version = var.oke_kubernetes_version
  name               = "${local.resource_name}-oke"
  vcn_id             = oci_core_vcn.dicom.id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = local.tags

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    is_public_ip_enabled = false
    subnet_id            = oci_core_subnet.oke_api.id
    nsg_ids              = [local.oke_api_nsg.id]
  }

  options {
    kubernetes_network_config {
      services_cidr = var.oke_services_cidr
    }

    service_lb_config {
      backend_nsg_ids = [local.oke_nodes_nsg.id]
      freeform_tags   = local.tags
    }

    persistent_volume_config {
      freeform_tags = local.tags
    }
  }

  lifecycle {
    precondition {
      condition     = contains(data.oci_containerengine_cluster_option.versions.kubernetes_versions, var.oke_kubernetes_version)
      error_message = "${var.oke_kubernetes_version} is not offered by OKE in ${var.region}."
    }

    precondition {
      condition     = local.calico_release != null
      error_message = "No Oracle-supported Calico policy-only release is mapped for ${var.oke_kubernetes_version}; use a supported Kubernetes 1.33-1.36 release or update the compatibility map."
    }
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

resource "oci_containerengine_node_pool" "orthanc" {
  cluster_id         = oci_containerengine_cluster.orthanc.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.oke_kubernetes_version
  name               = "${local.resource_name}-workers"
  node_shape         = var.oke_node_shape
  ssh_public_key     = local.bastion_ssh_public_key
  freeform_tags      = local.tags

  # Some tenancies enforce IMDSv2-only instances. OKE otherwise sends the
  # legacy-compatible default (false) to Compute, which makes every worker
  # launch fail in those tenancies. Oracle documents this node_metadata key as
  # the supported OKE control for disabling the IMDSv1 endpoint.
  node_metadata = {
    areLegacyImdsEndpointsDisabled = "true"
  }

  node_shape_config {
    ocpus         = var.oke_node_ocpus
    memory_in_gbs = var.oke_node_memory_gb
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.oke_node_image_id
    boot_volume_size_in_gbs = var.oke_node_boot_volume_gb
  }

  node_config_details {
    size    = var.oke_node_count
    nsg_ids = [local.oke_nodes_nsg.id]

    dynamic "placement_configs" {
      for_each = data.oci_identity_availability_domains.available.availability_domains

      content {
        availability_domain = placement_configs.value.name
        subnet_id           = oci_core_subnet.oke_nodes.id
      }
    }

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = var.oke_max_pods_per_node
      pod_nsg_ids       = [local.oke_pods_nsg.id]
      pod_subnet_ids    = [oci_core_subnet.oke_pods.id]
    }
  }

  initial_node_labels {
    key   = "oci-dicom.oracle.com/workload"
    value = "orthanc"
  }

  node_eviction_node_pool_settings {
    # A full stack destroy must not remain blocked indefinitely by a
    # PodDisruptionBudget or a pod that cannot complete graceful eviction.
    eviction_grace_duration              = "PT5M"
    is_force_delete_after_grace_duration = true
  }

  lifecycle {
    precondition {
      condition     = local.oke_node_image_id != ""
      error_message = "No non-GPU ${local.oke_node_arch} OKE node image was found for ${var.oke_kubernetes_version} in ${var.region}."
    }
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
